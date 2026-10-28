"""Test-only HTTPS proxy to the isolated API on127.0.0.1:8091. Run inside the native acceptance container; never expose beyond loopback."""
import http.server,ssl,urllib.request,urllib.error,pathlib
class Proxy(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):self.forward()
 def do_POST(self):self.forward()
 def forward(self):
  if self.path.startswith('/templates/'):
   name=self.path.removeprefix('/templates/')
   if name not in ['SBCO_Setup_Template.xlsx','SBCO_SO_Transactions_Template.xlsx','SBCO_BO_Transactions_Template.xlsx']:self.send_error(404);return
   body=(pathlib.Path('/work/apps/web/public/templates')/name).read_bytes();self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
  headers={name:value for name,value in self.headers.items() if name.lower() in ['cookie','content-type','x-sbco-request','x-sbco-training']}
  request=urllib.request.Request('http://127.0.0.1:8091'+self.path,data=self.rfile.read(int(self.headers.get('Content-Length',0))) if self.command=='POST' else None,headers=headers,method=self.command)
  try:response=urllib.request.urlopen(request,timeout=60)
  except urllib.error.HTTPError as error:response=error
  body=response.read();self.send_response(response.status)
  for name,value in response.headers.items():
   if name.lower() in ['set-cookie','content-type','content-disposition']:self.send_header(name,value)
  self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy);context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain('/tmp/tls/server.crt','/tmp/tls/server.key');server.socket=context.wrap_socket(server.socket,server_side=True);pathlib.Path('/tmp/connected-origin').write_text('https://localhost:'+str(server.server_address[1]));server.serve_forever()
