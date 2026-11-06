# Usage: mkct.py stub.o payload.bin out.o — stub.o with the operator:system component type as a custom section.
import sys
def leb(n):
    o=b''
    while True:
        c=n&127; n>>=7
        o+=bytes([c|(128 if n else 0)])
        if not n: return o
def name(s): s=s.encode(); return leb(len(s))+s
body=name('component-type:operator_system')+open(sys.argv[2],'rb').read()
open(sys.argv[3],'wb').write(open(sys.argv[1],'rb').read()+b'\0'+leb(len(body))+body)
