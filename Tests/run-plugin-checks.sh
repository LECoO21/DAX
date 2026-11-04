#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DAX_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dax-plugin-tests.XXXXXX")"
DAX_SERVER_PID=""
cleanup() {
  if [[ -n "$DAX_SERVER_PID" ]]; then kill "$DAX_SERVER_PID" 2>/dev/null || true; wait "$DAX_SERVER_PID" 2>/dev/null || true; fi
  rm -r "$DAX_TEST_DIR"
}
trap cleanup EXIT
python3 - "$DAX_TEST_DIR/port" <<'PY' &
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, sys, time
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  if self.path == '/v1/chat/completions':
   if data.get('stream'):
    result=('data: '+json.dumps({'choices':[{'delta':{'content':'Public fixture translation'}}]})+'\n\ndata: [DONE]\n\n').encode()
    self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(result)));self.end_headers();self.wfile.write(result);return
   result=json.dumps({'choices':[{'message':{'content':'Public fixture translation'}}]}).encode()
  else: result=json.dumps({'echo':data['text']}).encode()
  self.send_response(200); self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(result)));self.end_headers();self.wfile.write(result)
 def do_GET(self):
  if self.path.startswith('/tts'):
   result=b'RIFFfixture';self.send_response(200);self.send_header('Content-Type','audio/wav');self.send_header('Content-Length',str(len(result)));self.end_headers();self.wfile.write(result);return
  result='你好 世界'.encode()
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(result)));self.end_headers()
  for byte in result:
   self.wfile.write(bytes([byte]));self.wfile.flush();time.sleep(.01)
server=HTTPServer(('127.0.0.1',0),Handler)
open(sys.argv[1],'w').write(str(server.server_port))
server.serve_forever()
PY
DAX_SERVER_PID=$!
for attempt in {1..100}; do [[ -s "$DAX_TEST_DIR/port" ]] && break; sleep 0.03; done
export DAX_TEST_ENDPOINT="http://127.0.0.1:$(cat "$DAX_TEST_DIR/port")"
xcrun swiftc -parse-as-library Sources/DAX/KeychainAccess.swift Sources/DAX/Plugins.swift Sources/DAX/PluginWorker.swift Tests/PluginRuntimeChecks.swift -o "$DAX_TEST_DIR/plugin-checks"
"$DAX_TEST_DIR/plugin-checks"
