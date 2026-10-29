import Foundation
import Darwin

/// A login shell on a PTY, for one viewer. Output is delivered through `onOutput`; `onExit` fires once when the shell ends.
nonisolated final class TerminalHost: @unchecked Sendable {
    private var master: Int32 = -1
    private var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "canopy.remote.terminal")
    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable () -> Void
    private var finished = false

    init(onOutput: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) {
        self.onOutput = onOutput; self.onExit = onExit
    }

    func start(cols: Int, rows: Int) {
        queue.async { [self] in
            guard master < 0 else { return }
            var size = winsize(ws_row: UInt16(clamping: max(rows, 1)), ws_col: UInt16(clamping: max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let home = NSHomeDirectory()
            // Everything the child needs is built before forkpty; only exec runs in the child.
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-l"), nil]
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"; env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
            let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
            let cwd = strdup(home)
            defer { argv.forEach { free($0) }; envp.forEach { free($0) }; free(cwd) }

            var fd: Int32 = -1
            let child = forkpty(&fd, nil, nil, &size)
            if child == 0 {
                chdir(cwd)
                execve(shell, argv, envp)
                _exit(127)
            }
            guard child > 0 else { finish(); return }
            master = fd; pid = child
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.readAvailable() }
            readSource = src
            src.resume()
        }
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        let n = read(master, &buf, buf.count)
        if n > 0 { onOutput(Data(buf[0..<n])) }
        else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { finish() }
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard master >= 0 else { return }
            var offset = 0
            data.withUnsafeBytes { raw in
                while offset < raw.count {
                    let n = Darwin.write(master, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n } else if n < 0 && (errno == EAGAIN || errno == EINTR) { usleep(1000) } else { break }
                }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        queue.async { [self] in
            guard master >= 0 else { return }
            var size = winsize(ws_row: UInt16(clamping: max(rows, 1)), ws_col: UInt16(clamping: max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(master, TIOCSWINSZ, &size)
        }
    }

    /// Ends the shell (hangs it up) and closes the PTY. Safe to call more than once.
    func stop() { queue.async { [self] in finish(notify: false) } }

    private func finish(notify: Bool = true) {
        guard !finished else { return }
        finished = true
        readSource?.cancel(); readSource = nil
        if master >= 0 { close(master); master = -1 }
        if pid > 0 {
            kill(pid, SIGHUP)
            let p = pid; pid = 0
            DispatchQueue.global().async { var status: Int32 = 0; waitpid(p, &status, 0) }
        }
        if notify { onExit() }
    }
}
