import Foundation

/// How a file's comments are written.
public enum CommentStyle: Equatable, Sendable {
    case line(String)
    /// Languages with only block comments (CSS, HTML): every line is wrapped on its own.
    case block(open: String, close: String)
}

/// Which shell a script is for: decides `bash -n` / `sh -n` and the shellcheck dialect. Other shells (zsh, ksh, fish)
/// are not checked, since bash would reject their syntax.
public enum ShellDialect: Equatable, Sendable {
    case bash, sh, other
}

/// What an edited file is, for comment toggling, server-side checks and config tests. Finer than `SyntaxLanguage`,
/// which only decides colours.
public enum EditorFileKind: Equatable, Sendable {
    case plain, php, phpIni, phpFpm, nginx, apache, htaccess
    case javascript, typescript, json, jsonc, python, ruby, shell, yaml, crontab
    case toml, ini, env, dockerfile, sql, lua, css, html, cLike, conf

    public var commentStyle: CommentStyle? {
        switch self {
        case .plain, .json: nil
        case .php, .javascript, .typescript, .jsonc, .cLike: .line("//")
        case .shell, .python, .ruby, .yaml, .crontab, .toml, .env, .dockerfile, .nginx, .apache, .htaccess, .conf:
            .line("#")
        case .phpIni, .phpFpm, .ini: .line(";")
        case .sql, .lua: .line("--")
        case .css: .block(open: "/*", close: "*/")
        case .html: .block(open: "<!--", close: "-->")
        }
    }

    public var isJSON: Bool { self == .json }
}

/// The result of classifying a file.
public struct FileClassification: Equatable, Sendable {
    public var kind: EditorFileKind
    /// Only for `.shell`.
    public var dialect: ShellDialect

    public init(kind: EditorFileKind, dialect: ShellDialect = .bash) {
        self.kind = kind
        self.dialect = dialect
    }

    /// Classifies by file name, then folder (`/etc/nginx/`, `/etc/php/8.2/fpm/`), then a `#!` first line.
    public static func detect(fileName: String, path: String = "", firstLine: String = "") -> FileClassification {
        let name = fileName.lowercased()
        let lowerPath = path.lowercased()
        let ext = name.dropFirst().contains(".") ? String(name.split(separator: ".").last ?? "") : ""
        let shebang = parseShebang(firstLine)

        func shell(_ fallback: ShellDialect = .bash) -> FileClassification {
            FileClassification(kind: .shell, dialect: shebang?.dialect ?? fallback)
        }

        if name == "dockerfile" || name == "containerfile" || name.hasPrefix("dockerfile.") || ext == "dockerfile" {
            return .init(kind: .dockerfile)
        }
        if name == ".htaccess" { return .init(kind: .htaccess) }
        if name == "php.ini" || name == ".user.ini" || (ext == "ini" && lowerPath.contains("/etc/php")) {
            return .init(kind: .phpIni)
        }
        if name == "crontab" || lowerPath.hasPrefix("/etc/cron") || lowerPath.hasPrefix("/var/spool/cron") {
            return .init(kind: .crontab)
        }
        if name.hasPrefix(".env") || name == "env" || ext == "env" { return .init(kind: .env) }

        let configLike = ["", "conf", "vhost", "load", "include", "site"].contains(ext)
        if name == "nginx.conf" || ext == "nginx" || (lowerPath.contains("/nginx/") && configLike) {
            return .init(kind: .nginx)
        }
        if name == "httpd.conf" || name == "apache2.conf" || ((lowerPath.contains("/apache2/") || lowerPath.contains("/httpd/")) && configLike) {
            return .init(kind: .apache)
        }
        if name == "php-fpm.conf" || ((lowerPath.contains("/etc/php") && lowerPath.contains("/fpm/")
            || lowerPath.hasPrefix("/etc/php-fpm") || lowerPath.contains("/php-fpm.d/")) && ext == "conf") {
            return .init(kind: .phpFpm)
        }

        let dotfileShells = [".bashrc", ".zshrc", ".profile", ".bash_profile", ".bash_aliases", ".zprofile"]
        if dotfileShells.contains(name) { return shell(name.contains("zsh") ? .other : .bash) }

        switch ext {
        case "php", "phtml", "inc": return .init(kind: .php)
        case "js", "jsx", "mjs", "cjs": return .init(kind: .javascript)
        case "ts", "tsx", "mts", "cts": return .init(kind: .typescript)
        case "json", "webmanifest": return .init(kind: .json)
        case "jsonc": return .init(kind: .jsonc)
        case "yml", "yaml": return .init(kind: .yaml)
        case "py", "pyw": return .init(kind: .python)
        case "rb", "rake", "gemspec": return .init(kind: .ruby)
        case "sh", "bash": return shell()
        case "zsh", "ksh", "fish": return .init(kind: .shell, dialect: .other)
        case "toml": return .init(kind: .toml)
        case "ini": return .init(kind: .ini)
        case "sql": return .init(kind: .sql)
        case "lua": return .init(kind: .lua)
        case "css": return .init(kind: .css)
        case "html", "htm", "xhtml", "xml", "svg", "twig", "vue": return .init(kind: .html)
        case "scss", "less", "c", "h", "cpp", "hpp", "cc", "java", "go", "rs", "swift", "kt", "cs":
            return .init(kind: .cLike)
        case "conf", "cnf", "cfg", "properties", "service", "gitignore", "dockerignore":
            return .init(kind: .conf)
        default: break
        }
        if ["gemfile", "rakefile", "vagrantfile"].contains(name) { return .init(kind: .ruby) }
        if name == "makefile" || name == ".gitignore" || name == ".dockerignore" { return .init(kind: .conf) }

        if let shebang { return FileClassification(kind: shebang.kind, dialect: shebang.dialect) }
        return .init(kind: .plain)
    }

    private static func parseShebang(_ line: String) -> (kind: EditorFileKind, dialect: ShellDialect)? {
        guard line.hasPrefix("#!") else { return nil }
        var words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard var program = words.first.map({ RemotePathName.last($0) }) else { return nil }
        if program == "env" {
            words.removeFirst()
            guard let next = words.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) else { return nil }
            program = RemotePathName.last(next)
        }
        switch program {
        case "sh", "dash", "ash": return (.shell, .sh)
        case "bash": return (.shell, .bash)
        case "zsh", "ksh", "fish", "csh", "tcsh", "mksh": return (.shell, .other)
        case "php": return (.php, .bash)
        case "node", "nodejs", "deno", "bun": return (.javascript, .bash)
        case "ruby": return (.ruby, .bash)
        case "perl": return (.conf, .bash)
        default:
            if program.hasPrefix("python") || program == "pypy" || program == "pypy3" { return (.python, .bash) }
            return nil
        }
    }
}

enum RemotePathName {
    static func last(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// Quotes a string as one POSIX shell word.
public enum ShellWord {
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
