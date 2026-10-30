// sh for the app: mvdan.cc/sh (a POSIX and bash interpreter written as a library) as an ios_system command. Its state
// lives in its own Runner, not in globals, so any number run at once, unlike dash, which needs a copy of its
// framework for each (and ios_system has six). Commands run through ios_system (exec.c); builtins, functions,
// pipelines, subshells, here-documents and redirections are the interpreter's.
package main

/*
#include <stdlib.h>
int operator_sh_exec(char **argv, char **environment, const char *directory, int input, int output, int errors,
                     const void *context, int interrupts, volatile int *stop);
int operator_sh_interrupts(const void *context);
int operator_sh_executable(const char *name);
*/
import "C"

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"mvdan.cc/sh/v3/expand"
	"mvdan.cc/sh/v3/interp"
	"mvdan.cc/sh/v3/syntax"
)

func main() {}

//export operatorShRun
func operatorShRun(argc C.int, argv **C.char, input, output, errs C.int, session unsafe.Pointer, environment **C.char) C.int {
	args := cStrings(unsafe.Pointer(argv), int(argc))
	env := cStrings(unsafe.Pointer(environment), -1)
	stdin := os.NewFile(uintptr(input), "/dev/stdin")
	stdout := os.NewFile(uintptr(output), "/dev/stdout")
	stderr := os.NewFile(uintptr(errs), "/dev/stderr")
	defer stdin.Close()
	defer stdout.Close()
	defer stderr.Close()
	s := &shell{session: session, stdin: stdin, stdout: stdout, stderr: stderr}
	if len(args) > 0 {
		s.name = filepath.Base(args[0])
		args = args[1:]
	}
	return C.int(s.main(args, env))
}

/// A C array of strings (NULL-terminated when count is -1).
func cStrings(array unsafe.Pointer, count int) []string {
	var result []string
	if array == nil {
		return result
	}
	items := (*[1 << 28]*C.char)(array)
	for i := 0; count < 0 || i < count; i++ {
		if items[i] == nil {
			break
		}
		result = append(result, C.GoString(items[i]))
	}
	return result
}

type shell struct {
	name                  string
	session               unsafe.Pointer
	stdin, stdout, stderr *os.File
	runner                *interp.Runner
	/// The environment it started with: the runner reads it only when it first runs (for the first prompt).
	env []string
	/// The session's interrupt count when the running line started: a command stops once it changes.
	interrupts atomic.Int32
}

func (s *shell) main(args []string, env []string) int {
	s.env = env
	var command *string
	interactive, readStdin := false, false
	var options []string
	for len(args) > 0 && len(args[0]) > 1 && (args[0][0] == '-' || args[0][0] == '+') {
		arg := args[0]
		args = args[1:]
		if arg == "--" {
			break
		}
		if arg == "-o" || arg == "+o" {
			if len(args) > 0 {
				options = append(options, arg, args[0])
				args = args[1:]
			}
			continue
		}
		for _, letter := range arg[1:] {
			switch letter {
			case 'c':
				if len(args) == 0 {
					fmt.Fprintf(s.stderr, "%s: -c: option requires an argument\n", s.name)
					return 2
				}
				command = &args[0]
				args = args[1:]
			case 'i':
				interactive = true
			case 's':
				readStdin = true
			case 'l':
				// a login shell: nothing more to read on this device
			default:
				options = append(options, string(arg[0])+string(letter))
			}
		}
	}
	directory, _ := os.Getwd()
	runner, err := interp.New(
		interp.StdIO(s.stdin, s.stdout, s.stderr),
		interp.Env(expand.ListEnviron(env...)),
		interp.Dir(directory),
		interp.Interactive(interactive),
		interp.ExecHandlers(s.execMiddleware),
	)
	if err != nil {
		fmt.Fprintf(s.stderr, "%s: %v\n", s.name, err)
		return 2
	}
	s.runner = runner
	switch {
	case command != nil:
		// sh -c 'command' [name [arguments...]]
		if len(args) > 0 {
			s.name = args[0]
			args = args[1:]
		}
		if err := interp.Params(append(options, append([]string{"--"}, args...)...)...)(runner); err != nil {
			fmt.Fprintf(s.stderr, "%s: %v\n", s.name, err)
			return 2
		}
		return s.runSource(strings.NewReader(*command), s.name)
	case len(args) > 0 && !readStdin && !interactive:
		// sh script [arguments...]
		file, err := os.Open(args[0])
		if err != nil {
			fmt.Fprintf(s.stderr, "%s: %s: %v\n", s.name, args[0], unwrapPath(err))
			return 127
		}
		defer file.Close()
		if err := interp.Params(append(options, append([]string{"--"}, args[1:]...)...)...)(runner); err != nil {
			fmt.Fprintf(s.stderr, "%s: %v\n", s.name, err)
			return 2
		}
		return s.runSource(file, args[0])
	default:
		if err := interp.Params(append(options, append([]string{"--"}, args...)...)...)(runner); err != nil {
			fmt.Fprintf(s.stderr, "%s: %v\n", s.name, err)
			return 2
		}
		if interactive {
			return s.interactive()
		}
		return s.runSource(s.stdin, s.name)
	}
}

func unwrapPath(err error) error {
	var pathError *os.PathError
	if errors.As(err, &pathError) {
		return pathError.Err
	}
	return err
}

/// Runs a whole script; an interrupt (Ctrl-C, a timeout) stops it with 130.
func (s *shell) runSource(source io.Reader, name string) int {
	file, err := syntax.NewParser().Parse(source, name)
	if err != nil {
		fmt.Fprintf(s.stderr, "%s: %v\n", s.name, err)
		return 2
	}
	ctx, stop := s.interruptible()
	defer stop()
	return s.status(s.runner.Run(ctx, file), ctx)
}

/// A context cancelled when the session is interrupted after this point.
func (s *shell) interruptible() (context.Context, func()) {
	ctx, cancel := context.WithCancel(context.Background())
	start := C.operator_sh_interrupts(s.session)
	s.interrupts.Store(int32(start))
	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				if C.operator_sh_interrupts(s.session) != start {
					cancel()
					return
				}
			}
		}
	}()
	return ctx, func() { close(done); cancel() }
}

var errInterrupted = errors.New("interrupted")

func (s *shell) status(err error, ctx context.Context) int {
	if ctx.Err() != nil || errors.Is(err, errInterrupted) {
		return 130
	}
	if err == nil {
		return 0
	}
	if code, ok := interp.IsExitStatus(err); ok {
		return int(code)
	}
	fmt.Fprintf(s.stderr, "%s: %v\n", s.name, err)
	return 1
}

/// sh -i: reads lines, runs each complete command, and prints the prompt ($PS1, expanded; $PS2 on a continued line).
func (s *shell) interactive() int {
	parser := syntax.NewParser()
	s.prompt("PS1", "$ ")
	status := 0
	err := parser.Interactive(s.stdin, func(statements []*syntax.Stmt) bool {
		if parser.Incomplete() {
			s.prompt("PS2", "> ")
			return true
		}
		ctx, stop := s.interruptible()
		for _, statement := range statements {
			status = s.status(s.runner.Run(ctx, statement), ctx)
			if s.runner.Exited() || ctx.Err() != nil {
				break
			}
		}
		stop()
		if s.runner.Exited() {
			return false
		}
		s.prompt("PS1", "$ ")
		return true
	})
	if err != nil && !s.runner.Exited() {
		fmt.Fprintf(s.stderr, "%s: %v\n", s.name, err)
	}
	return status
}

func (s *shell) prompt(name, fallback string) {
	text := fallback
	if variable := s.runner.Vars[name]; variable.IsSet() {
		text = variable.String()
	} else if value := s.environ().Get(name); value.IsSet() {
		text = value.String()
	}
	if word, err := syntax.NewParser().Document(strings.NewReader(text)); err == nil {
		config := &expand.Config{Env: s.environ()}
		if expanded, err := expand.Document(config, word); err == nil {
			text = expanded
		}
	}
	io.WriteString(s.stdout, text)
}

/// The runner's variables (PWD is its directory), for expanding the prompt.
func (s *shell) environ() expand.Environ {
	return expand.FuncEnviron(func(name string) string {
		if name == "PWD" {
			return s.runner.Dir
		}
		if variable, ok := s.runner.Vars[name]; ok {
			return variable.String()
		}
		for _, entry := range s.env {
			if strings.HasPrefix(entry, name+"=") {
				return entry[len(name)+1:]
			}
		}
		return ""
	})
}

// MARK: Commands

func (s *shell) execMiddleware(next interp.ExecHandlerFunc) interp.ExecHandlerFunc {
	return func(ctx context.Context, args []string) error {
		hc := interp.HandlerCtx(ctx)
		program := args[0]
		// Programs clang builds are WebAssembly whatever their name; ios_system knows only name.wasm.
		if program == "sh" || program == "bash" {
			// The command itself (aliases name it elsewhere; see exec.c).
			args = append([]string{"operator-sh"}, args[1:]...)
		} else if module := webAssemblyFile(program, hc); module != "" {
			args = append([]string{"wasm", module}, args[1:]...)
		} else if script := shellScript(program, hc); script != "" {
			// A shell script runs in a new interpreter (as `sh script`), there being no exec.
			args = append([]string{"operator-sh", script}, args[1:]...)
		} else if !strings.Contains(program, "/") && C.operator_sh_executable(cString(program)) == 0 {
			fmt.Fprintf(hc.Stderr, "%s: %s: command not found\n", s.name, program)
			return interp.ExitStatus(127)
		}
		return s.run(ctx, hc, args)
	}
}

var cStringsLock sync.Mutex
var cStringCache = map[string]*C.char{}

/// A C string kept for the life of the app (command names are few).
func cString(text string) *C.char {
	cStringsLock.Lock()
	defer cStringsLock.Unlock()
	if value, ok := cStringCache[text]; ok {
		return value
	}
	value := C.CString(text)
	if len(cStringCache) < 4096 {
		cStringCache[text] = value
	}
	return value
}

/// Runs a command through ios_system with the interpreter's directory, exported variables and streams.
func (s *shell) run(ctx context.Context, hc interp.HandlerContext, args []string) error {
	in, closeIn, err := readFile(hc.Stdin)
	if err != nil {
		return err
	}
	defer closeIn()
	out, finishOut, err := writeFile(hc.Stdout)
	if err != nil {
		return err
	}
	errs, finishErr := out, func() {}
	if hc.Stderr != hc.Stdout {
		if errs, finishErr, err = writeFile(hc.Stderr); err != nil {
			finishOut()
			return err
		}
	}

	argv := cArray(args)
	defer freeArray(argv, len(args))
	var exported []string
	hc.Env.Each(func(name string, variable expand.Variable) bool {
		if variable.Exported && variable.IsSet() {
			exported = append(exported, name+"="+variable.String())
		}
		return true
	})
	env := cArray(exported)
	defer freeArray(env, len(exported))
	directory := C.CString(hc.Dir)
	defer C.free(unsafe.Pointer(directory))

	// Set (by this goroutine) when the interpreter is interrupted; read by exec.c while it waits. Freed only after
	// the goroutine has ended.
	stop := (*C.int)(C.malloc(C.size_t(unsafe.Sizeof(C.int(0)))))
	*stop = 0
	finished, watched := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(watched)
		select {
		case <-ctx.Done():
			atomic.StoreInt32((*int32)(unsafe.Pointer(stop)), 1)
		case <-finished:
		}
	}()
	code := C.operator_sh_exec(argv, env, directory, C.int(in.Fd()), C.int(out.Fd()), C.int(errs.Fd()), s.session,
		C.int(s.interrupts.Load()), stop)
	close(finished)
	<-watched
	finishErr()
	finishOut()
	// Interrupted (Ctrl-C, a timeout): the whole line stops, not just this command (an error other than an exit
	// status halts the runner). exec.c sets stop to 2 when it stopped the command for an interrupt, which may come
	// before the context is cancelled.
	if ctx.Err() != nil || atomic.LoadInt32((*int32)(unsafe.Pointer(stop))) == 2 {
		C.free(unsafe.Pointer(stop))
		return errInterrupted
	}
	C.free(unsafe.Pointer(stop))
	if code != 0 {
		return interp.ExitStatus(uint8(code))
	}
	return nil
}

func cArray(items []string) **C.char {
	array := (*[1 << 28]*C.char)(C.malloc(C.size_t(len(items)+1) * C.size_t(unsafe.Sizeof((*C.char)(nil)))))
	for i, item := range items {
		array[i] = C.CString(item)
	}
	array[len(items)] = nil
	return &array[0]
}

func freeArray(array **C.char, count int) {
	items := (*[1 << 28]*C.char)(unsafe.Pointer(array))
	for i := 0; i < count; i++ {
		C.free(unsafe.Pointer(items[i]))
	}
	C.free(unsafe.Pointer(array))
}

/// A descriptor for the command's input: the interpreter's file, or a pipe fed from its reader.
func readFile(reader io.Reader) (*os.File, func(), error) {
	if file, ok := reader.(*os.File); ok {
		return file, func() {}, nil
	}
	if reader == nil {
		file, err := os.Open(os.DevNull)
		return file, func() { file.Close() }, err
	}
	r, w, err := os.Pipe()
	if err != nil {
		return nil, nil, err
	}
	go func() { io.Copy(w, reader); w.Close() }()
	return r, func() { r.Close() }, nil
}

/// A descriptor for the command's output: the interpreter's file, or a pipe copied into its writer (command
/// substitution writes to a buffer). The returned function waits until everything is copied.
func writeFile(writer io.Writer) (*os.File, func(), error) {
	if file, ok := writer.(*os.File); ok {
		return file, func() {}, nil
	}
	if writer == nil {
		writer = io.Discard
	}
	r, w, err := os.Pipe()
	if err != nil {
		return nil, nil, err
	}
	done := make(chan struct{})
	go func() { io.Copy(writer, r); r.Close(); close(done) }()
	return w, func() { w.Close(); <-done }, nil
}

/// The WebAssembly file a program names: a path, or a name on PATH that is not an ios_system command.
func webAssemblyFile(program string, hc interp.HandlerContext) string {
	if program == "wasm" {
		return ""
	}
	var candidates []string
	if strings.Contains(program, "/") {
		candidates = []string{absolute(program, hc)}
	} else if C.operator_sh_executable(cString(program)) == 0 {
		for _, dir := range filepath.SplitList(hc.Env.Get("PATH").String()) {
			candidates = append(candidates, filepath.Join(dir, program))
		}
	}
	for _, path := range candidates {
		if hasPrefix(path, []byte("\x00asm")) {
			return path
		}
	}
	return ""
}

/// A file named by path that is a shell script: `#!` naming sh, bash or dash, or text without `#!`.
func shellScript(program string, hc interp.HandlerContext) string {
	if !strings.Contains(program, "/") {
		return ""
	}
	path := absolute(program, hc)
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	head := make([]byte, 128)
	n, _ := file.Read(head)
	head = head[:n]
	if bytes.HasPrefix(head, []byte("#!")) {
		line := string(head[2:])
		if end := strings.IndexByte(line, '\n'); end >= 0 {
			line = line[:end]
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			return ""
		}
		interpreter := filepath.Base(fields[0])
		if interpreter == "env" && len(fields) > 1 {
			interpreter = fields[1]
		}
		if interpreter == "sh" || interpreter == "bash" || interpreter == "dash" {
			return path
		}
		return ""
	}
	if n > 0 && !bytes.ContainsRune(head, 0) {
		return path
	}
	return ""
}

func absolute(path string, hc interp.HandlerContext) string {
	if strings.HasPrefix(path, "~/") {
		path = filepath.Join(hc.Env.Get("HOME").String(), path[2:])
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(hc.Dir, path)
	}
	return path
}

func hasPrefix(path string, prefix []byte) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	head := make([]byte, len(prefix))
	n, _ := io.ReadFull(file, head)
	return n == len(prefix) && bytes.Equal(head, prefix)
}
