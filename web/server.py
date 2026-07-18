#!/usr/bin/env python3
"""cka-practice 웹 UI 백엔드 — Python 표준 라이브러리만 사용.

왼쪽 패널(지문/버튼/결과)을 서빙하고, 액션은 기존 `cka` CLI에 위임한다.
오른쪽 패널의 실제 터미널은 ttyd(별도 포트)가 담당한다.
"""
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CKA_ROOT = os.environ.get("CKA_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(CKA_ROOT, "web")
STATE_DIR = os.path.join(CKA_ROOT, ".state", "status")
QUESTIONS_DIR = os.path.join(CKA_ROOT, "questions")

# 도메인 표시 순서 (cka CLI의 DOMAIN_ORDER와 동일)
DOMAIN_ORDER = [
    "troubleshooting",
    "cluster-architecture",
    "services-networking",
    "workloads-scheduling",
    "storage",
]

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def strip_ansi(text):
    return ANSI_RE.sub("", text)


def meta_get(qdir, key):
    """meta.yaml에서 단순 key: value 읽기 (lib/common.sh meta_get와 동일)."""
    path = os.path.join(qdir, "meta.yaml")
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith(key + ":"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return ""


def state_get(qid):
    path = os.path.join(STATE_DIR, qid)
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return "-"


def list_questions():
    result = []
    for domain in DOMAIN_ORDER:
        ddir = os.path.join(QUESTIONS_DIR, domain)
        if not os.path.isdir(ddir):
            continue
        for qid in sorted(os.listdir(ddir)):
            qdir = os.path.join(ddir, qid)
            if not os.path.isdir(qdir):
                continue
            result.append({
                "id": qid,
                "domain": domain,
                "title": meta_get(qdir, "title"),
                "points": meta_get(qdir, "points"),
                "minutes": meta_get(qdir, "minutes"),
                "status": state_get(qid),
            })
    return result


def question_detail(qid):
    for domain in DOMAIN_ORDER:
        qdir = os.path.join(QUESTIONS_DIR, domain, qid)
        if os.path.isdir(qdir):
            try:
                with open(os.path.join(qdir, "question.md"), encoding="utf-8") as f:
                    body = f.read()
            except OSError:
                body = "(지문을 읽을 수 없습니다)"
            return {
                "id": qid,
                "domain": domain,
                "title": meta_get(qdir, "title"),
                "points": meta_get(qdir, "points"),
                "minutes": meta_get(qdir, "minutes"),
                "question": body,
                "status": state_get(qid),
            }
    return None


def run_cka(args, timeout=300):
    """`cka` CLI를 실행하고 ANSI 제거된 출력을 반환."""
    cmd = [os.path.join(CKA_ROOT, "cka")] + args
    env = dict(os.environ, CKA_ROOT=CKA_ROOT)
    try:
        proc = subprocess.run(
            cmd, cwd=CKA_ROOT, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        return proc.returncode, strip_ansi(proc.stdout.decode("utf-8", "replace"))
    except subprocess.TimeoutExpired:
        return 124, "(시간 초과: 명령이 %d초 안에 끝나지 않았습니다)" % timeout
    except Exception as exc:  # noqa: BLE001
        return 1, "(실행 오류: %s)" % exc


class Handler(BaseHTTPRequestHandler):
    server_version = "cka-web/1.0"

    def log_message(self, *args):  # 콘솔 스팸 억제
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False)
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _serve_file(self, name, ctype):
        try:
            with open(os.path.join(WEB_DIR, name), "rb") as f:
                self._send(200, f.read(), ctype)
        except OSError:
            self._send(404, {"error": "not found"})

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            return self._serve_file("index.html", "text/html; charset=utf-8")
        if path == "/api/questions":
            return self._send(200, list_questions())
        if path.startswith("/api/question/"):
            qid = path.rsplit("/", 1)[-1]
            detail = question_detail(qid)
            return self._send(200 if detail else 404, detail or {"error": "unknown id"})
        if path == "/api/exam/status":
            code, out = run_cka(["exam", "status"], timeout=30)
            return self._send(200, {"code": code, "output": out})
        if path.startswith("/api/exam/question/"):
            n = path.rsplit("/", 1)[-1]
            code, out = run_cka(["exam", "question", n], timeout=30)
            return self._send(200, {"code": code, "output": out})
        return self._send(404, {"error": "not found"})

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            return {}

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        payload = self._read_json()

        if path == "/api/action":
            cmd = payload.get("cmd", "")
            qid = payload.get("id", "")
            if cmd not in ("start", "grade", "solution", "reset") or not re.fullmatch(r"[a-z]{2}-\d{2}", qid or ""):
                return self._send(400, {"error": "invalid action"})
            # start/reset은 클러스터 셋업이 있어 오래 걸릴 수 있다
            timeout = 300 if cmd in ("start", "reset") else 60
            code, out = run_cka([cmd, qid], timeout=timeout)
            return self._send(200, {"code": code, "output": out, "status": state_get(qid)})

        if path == "/api/exam":
            cmd = payload.get("cmd", "")
            if cmd not in ("start", "finish", "abort"):
                return self._send(400, {"error": "invalid exam cmd"})
            timeout = 600 if cmd in ("start", "finish") else 60
            code, out = run_cka(["exam", cmd], timeout=timeout)
            return self._send(200, {"code": code, "output": out})

        return self._send(404, {"error": "not found"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7681
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("cka web server: http://127.0.0.1:%d (CKA_ROOT=%s)" % (port, CKA_ROOT), flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
