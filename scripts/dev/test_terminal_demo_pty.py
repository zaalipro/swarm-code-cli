#!/usr/bin/env python3
"""Live demo tests use an owned ctty; never touch the user's terminal."""
import codecs, fcntl, json, os, re, select, signal, struct, subprocess, sys, termios, time, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
LAUNCH = ROOT / 'scripts/dev/run_terminal_demo.sh'
CSI = re.compile(r'\x1b\[([0-?]*[ -/]*)([@-~])')

class Demo:
    def __init__(self, args=(), term='xterm-256color'):
        self.master, self.slave = os.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        mr, mw = os.pipe(); rr, self.release = os.pipe()
        env = dict(os.environ, TERM=term)
        self.holder = subprocess.Popen([sys.executable, __file__, '--holder', str(self.slave), str(mw), str(rr), *args], pass_fds=(self.slave,mw,rr), env=env)
        os.close(mw); os.close(rr)
        self.meta = os.fdopen(mr)
        info = json.loads(self.meta.readline())
        self.pid = info['pid']; self.original = info['termios']
        self.original[6] = [bytes([b]) if isinstance(b,int) else b for b in self.original[6]]
        self.output = bytearray(); self.status = None; self.children = set()
        self.cells=[[' ']*120 for _ in range(40)]; self.x=self.y=self.offset=0
        self.decoder=codecs.getincrementaldecoder('utf-8')('replace'); self.pending=''
    def pump(self):
        if select.select([self.master],[],[],.05)[0]:
            try: self.output.extend(os.read(self.master,65536))
            except OSError: pass
    def screen(self):
        # Incremental cell assertions for the project's explicit-position output.
        text=self.pending+self.decoder.decode(bytes(self.output[self.offset:])); self.offset=len(self.output)
        index=0
        while index<len(text):
            char=text[index]
            if char=='\x1b':
                match=CSI.match(text,index)
                if not match: break
                values=match[1].split(';'); code=match[2]
                if code=='H':
                    self.y=int(values[0] or '1')-1; self.x=int(values[1] or '1')-1 if len(values)>1 else 0
                elif code=='J' and values==['2']: self.cells=[[' ']*120 for _ in range(40)]
                elif code=='K' and 0<=self.y<40:
                    start,end=(0,120) if values==['2'] else (max(0,self.x),120)
                    self.cells[self.y][start:end]=[' ']*(end-start)
                index+=len(match[0]); continue
            if char=='\r': self.x=0
            elif char=='\n': self.y+=1
            elif char>=' ':
                if 0<=self.x<120 and 0<=self.y<40: self.cells[self.y][self.x]=char
                self.x+=1
            index+=1
        self.pending=text[index:]
        return '\n'.join(''.join(row) for row in self.cells).encode()
    def wait_for(self, marker, timeout=20):
        end = time.monotonic()+timeout
        while marker not in self.screen() and time.monotonic()<end:
            self.pump()
            if select.select([self.meta],[],[],0)[0]:
                self.status=int(self.meta.readline()); break
        assert marker in self.screen(), ('missing marker',marker,self.screen(),bytes(self.output[-2000:]))
    def capture(self, name):
        end=time.monotonic()+.2
        while time.monotonic()<end: self.pump()
        directory=ROOT/'_build/terminal-demo-captures'; directory.mkdir(parents=True,exist_ok=True)
        (directory/(name+'.ansi')).write_bytes(self.output)
        (directory/(name+'.txt')).write_bytes(self.screen())
        (directory/'dimensions.json').write_text(json.dumps({'columns':120,'rows':40})+'\n')
    def descendants(self):
        listing = subprocess.check_output(['ps','-axo','ppid=,pid=,comm='],text=True)
        rows = [line.split(None,2) for line in listing.splitlines()]
        found={self.pid}; changed=True
        while changed:
            changed=False
            for parent,pid,_ in rows:
                if int(parent) in found and int(pid) not in found:
                    found.add(int(pid)); changed=True
        self.children.update(found-{self.pid})
        return [(int(pid),name) for _,pid,name in rows if int(pid) in found-{self.pid}]
    def send(self, data): os.write(self.master,data)
    def finish(self, success=True):
        end = time.monotonic()+6
        while self.status is None and time.monotonic()<end:
            self.pump()
            if select.select([self.meta],[],[],0)[0]: self.status=int(self.meta.readline())
        assert self.status is not None, ('demo did not exit',bytes(self.output[-4000:]))
        if success: assert self.status == 0, (self.status,bytes(self.output[-4000:]))
        assert termios.tcgetattr(self.slave)==self.original, 'termios restoration differs'
        listing = subprocess.check_output(['ps','-axo','ppid=,pid='],text=True)
        assert not any(line.split()[0]==str(self.pid) for line in listing.splitlines()), 'child survived'
        for child in self.children:
            try: os.kill(child,0)
            except ProcessLookupError: pass
            else: raise AssertionError(('descendant survived',child))
    def close(self):
        try:
            if self.status is None:
                try: os.kill(self.pid,signal.SIGTERM)
                except ProcessLookupError: pass
                self.finish(False)
        finally:
            os.close(self.release); self.holder.wait(timeout=5)
            self.meta.close(); os.close(self.master); os.close(self.slave)

class LiveDemo(unittest.TestCase):
    def demo(self,*args,**kwargs):
        demo=Demo(*args,**kwargs); self.addCleanup(demo.close); return demo
    def test_live_banner_and_clean_detach(self):
        d=self.demo(); d.wait_for(b'NO USER DATA'); d.descendants(); d.send(b'q'); d.finish()
    def test_question_navigation_paste_and_dirty_cancel_confirm(self):
        d=self.demo(); d.wait_for(b'NO USER DATA'); d.descendants(); d.capture('workspace')
        d.send(b'a'); d.wait_for(b'Search:')
        d.send(b'Open question'); d.wait_for(b'Open question')
        d.send(b'\r'); d.wait_for(b'Which review should proceed?'); d.capture('question')
        d.send(b'2\r'); d.wait_for(b'ACCEPTED')
        for _ in range(2):
            d.send(b'\x1b')
            end=time.monotonic()+.15
            while time.monotonic()<end: d.pump()
        d.wait_for(b'Focus: main')
        for _ in range(4):
            d.send(b'\t')
            end=time.monotonic()+.2
            while time.monotonic()<end: d.pump()
            if b'Focus: composer' in d.screen(): break
        self.assertIn(b'Focus: composer',d.screen())
        d.send(b'\x1b[200~PTY draft marker\x1b[201~'); d.wait_for(b'PTY draft marker'); d.capture('composer')
        d.send(b'\x1b'); d.wait_for(b'Focus: main')
        d.send(b'q'); d.wait_for(b'UNSENT CHANGES'); d.capture('before-detach')
        d.send(b'\r'); d.wait_for(b'Focus: main')
        self.assertIn(b'PTY draft marker',d.screen())
        d.send(b'q'); d.wait_for(b'UNSENT CHANGES')
        d.send(b'\t\r'); d.finish()

    def test_killed_native_writer_restores_before_demo_returns(self):
        d=self.demo(); d.wait_for(b'NO USER DATA')
        native=[pid for pid,name in d.descendants() if name.endswith('swarm-terminal-port')]
        self.assertEqual(len(native),2)
        listing=subprocess.check_output(['ps','-axo','ppid=,pid='],text=True)
        writer=next(int(line.split()[1]) for line in listing.splitlines() if int(line.split()[0]) in native and int(line.split()[1]) in native)
        os.kill(writer,signal.SIGKILL)
        d.finish(False)
        self.assertNotEqual(d.status,0)

    def test_external_suspend_resume_barrier_then_input_and_detach(self):
        d=self.demo(); d.wait_for(b'NO USER DATA')
        native=[pid for pid,name in d.descendants() if name.endswith('swarm-terminal-port')]
        self.assertEqual(len(native),2)
        listing=subprocess.check_output(['ps','-axo','ppid=,pid='],text=True)
        guard=next(int(line.split()[0]) for line in listing.splitlines() if int(line.split()[0]) in native and int(line.split()[1]) in native)
        os.kill(guard,signal.SIGTSTP)
        end=time.monotonic()+3
        while termios.tcgetattr(d.slave)!=d.original and time.monotonic()<end: d.pump()
        self.assertEqual(termios.tcgetattr(d.slave),d.original)
        os.kill(guard,signal.SIGCONT)
        end=time.monotonic()+3
        while termios.tcgetattr(d.slave)==d.original and time.monotonic()<end: d.pump()
        self.assertNotEqual(termios.tcgetattr(d.slave),d.original)
        d.send(b'\t'); d.wait_for(b'Focus: composer')
        d.send(b'\x1b[200~After resume\x1b[201~'); d.wait_for(b'After resume')
        d.send(b'\x1b'); d.wait_for(b'Focus: main')
        d.send(b'q'); d.wait_for(b'UNSENT CHANGES'); d.send(b'\t\r'); d.finish()

    def test_no_alt_screen_and_closed_options(self):
        d=self.demo(('--no-alt-screen','--ascii','--monochrome','--ambiguous-width','wide','--reduced-motion'))
        d.wait_for(b'NO USER DATA'); d.descendants(); d.send(b'q'); d.finish()
        self.assertNotIn(b'\x1b[?1049h',d.output)
        self.assertNotIn(b'\x1b[?1049l',d.output)
    def test_invalid_option_rejected_before_modes(self):
        d=self.demo(('--arbitrary-path','/tmp/nope'))
        d.finish(False)
        self.assertNotEqual(d.status,0)
        self.assertNotIn(b'\x1b[?1049h',d.output)
        self.assertIn(b'Expected terminal options',d.output)
    def test_non_tty_and_dumb_rejected_without_modes(self):
        result=subprocess.run(['bash',str(LAUNCH)],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b'(cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)',result.stdout)
        self.assertNotIn(b'\x1b[?1049h',result.stdout)
        d=self.demo(term='dumb'); d.finish(False)
        self.assertNotEqual(d.status,0)
        self.assertIn(b'(cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)',d.output)
    def test_normal_vm_without_noinput_rejected(self):
        result=subprocess.run(['mise','exec','--','mix','swarm_code.demo.terminal'],cwd=ROOT/'apps/swarm_code_cli',stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b'requires -noinput',result.stdout)

def holder():
    slave,meta,release=map(int,sys.argv[2:5]); os.setsid(); fcntl.ioctl(slave,termios.TIOCSCTTY,0)
    original=termios.tcgetattr(slave); original[6]=[b[0] if isinstance(b,bytes) else b for b in original[6]]
    child=subprocess.Popen(['bash',str(LAUNCH),*sys.argv[5:]],stdin=slave,stdout=slave,stderr=slave,cwd=ROOT)
    os.write(meta,(json.dumps({'pid':child.pid,'termios':original})+'\n').encode())
    code=child.wait(); os.write(meta,(str(code)+'\n').encode()); os.read(release,1)
if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='--holder': holder()
    else: unittest.main()
