import Foundation

/// Conservative language guessing for unlabeled code fences. Only the first ~120 lines are inspected;
/// strong markers win outright, otherwise a small line-based score must clearly beat the runner-up.
enum SyntaxLanguageDetector {
    static let shellCommands: Set<String> = [
        "npm", "npx", "yarn", "pnpm", "bun", "bunx", "deno", "node", "pip", "pip3", "pipx", "python", "python3", "uv", "poetry",
        "conda", "brew", "git", "gh", "cd", "mkdir", "ls", "cp", "mv", "rm", "curl", "wget", "sudo", "apt", "apt-get",
        "yum", "dnf", "pacman", "docker", "docker-compose", "podman", "kubectl", "helm", "minikube", "cargo", "rustup",
        "go", "swift", "xcodebuild", "xcrun", "make", "cmake", "export", "echo", "source", "chmod", "chown", "touch",
        "cat", "grep", "sed", "awk", "tar", "unzip", "zip", "ssh", "scp", "rsync", "gem", "bundle", "rails", "rake",
        "composer", "php", "mvn", "gradle", "./gradlew", "java", "javac", "flutter", "dart", "dotnet", "systemctl",
        "service", "heroku", "vercel", "netlify", "firebase", "aws", "gcloud", "az", "terraform", "ansible",
        "ansible-playbook", "open", "code", "killall", "kill", "ps", "which", "env", "alias", "sh", "bash", "zsh",
        "ln", "find", "head", "tail", "less", "man", "sort", "uniq", "wc", "xargs", "tee", "jq", "openssl", "ping",
        "nc", "lsof", "top", "htop", "df", "du", "mount", "defaults", "launchctl", "pod", "fastlane", "swiftlint",
        "eslint", "prettier", "tsc", "vite", "next", "nx", "turbo", "jest", "pytest", "ruff", "black", "mypy", "uvicorn",
        "gunicorn", "flask", "django-admin", "hugo", "jekyll", "rbenv", "pyenv", "nvm", "volta", "asdf", "mise",
        "set", "unset", "cargo-watch", "wasm-pack", "zig", "grok", "crok", "claude", "codex"
    ]

    static let htmlTags: Set<String> = [
        "html", "head", "body", "div", "span", "p", "a", "ul", "ol", "li", "table", "tr", "td", "th", "form", "input",
        "button", "img", "section", "article", "header", "footer", "nav", "main", "h1", "h2", "h3", "h4", "h5", "h6",
        "script", "style", "link", "meta", "title", "label", "select", "option", "textarea", "br", "hr", "iframe",
        "canvas", "video", "audio", "template", "svg", "pre", "code", "em", "strong", "small", "aside", "figure"
    ]

    static func detect(_ code: String) -> SyntaxLanguage? {
        let sample = code.utf16.count > 8_000 ? String(code.prefix(6_000)) : code
        let trimmed = sample.drop(while: { $0.isWhitespace })
        guard !trimmed.isEmpty else { return nil }
        let lang = SyntaxLanguageRegistry.language(id:)

        // Shebangs and unambiguous prefixes.
        if trimmed.hasPrefix("#!") {
            let line = trimmed.prefix(while: { $0 != "\n" })
            for (needle, id) in [("python", "python"), ("node", "javascript"), ("deno", "typescript"), ("bun", "typescript"),
                                 ("ruby", "ruby"), ("perl", "perl"), ("php", "php"), ("zsh", "zsh"), ("fish", "fish"),
                                 ("bash", "bash"), ("/sh", "bash"), ("env sh", "bash"), ("pwsh", "powershell"), ("lua", "lua"),
                                 ("Rscript", "r"), ("swift", "swift"), ("julia", "julia"), ("elixir", "elixir"), ("awk", "awk")]
                where line.contains(needle) {
                return lang(id)
            }
        }
        if trimmed.hasPrefix("<?php") { return lang("php") }
        if trimmed.hasPrefix("<?xml") { return trimmed.contains("<plist") ? lang("plist") : (trimmed.contains("<svg") ? lang("svg") : lang("xml")) }
        if trimmed.lowercased().hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") { return lang("html") }
        if trimmed.hasPrefix("diff --git") || trimmed.hasPrefix("Index: ") || (trimmed.hasPrefix("--- ") && trimmed.contains("\n+++ ")) || trimmed.hasPrefix("@@ -") {
            return lang("diff")
        }
        if trimmed.hasPrefix("$ ") || trimmed.hasPrefix("% ") && trimmed.dropFirst(2).first?.isLetter == true { return lang("console") }
        if trimmed.hasPrefix(">>> ") { return lang("pycon") }
        if trimmed.hasPrefix("PS ") && trimmed.prefix(80).contains("> ") { return lang("console") }
        if let json = detectJSON(trimmed) { return json }

        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true).prefix(120).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        // Markup
        if trimmed.hasPrefix("<") {
            let name = trimmed.dropFirst().prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" }).lowercased()
            if name == "svg" { return lang("svg") }
            if name == "template" && sample.contains("<script") { return lang("vue") }
            if htmlTags.contains(name) { return lang("html") }
            if !name.isEmpty && (sample.contains("</") || sample.contains("/>")) { return lang("xml") }
        }

        // Dockerfile: first instruction is FROM / ARG.
        if let first = lines.first(where: { !$0.hasPrefix("#") }), first.hasPrefix("FROM ") || (first.hasPrefix("ARG ") && lines.contains(where: { $0.hasPrefix("FROM ") })) {
            return lang("dockerfile")
        }

        // Shell commands: every non-comment line starts with a well-known command.
        let commandLines = lines.filter { !$0.hasPrefix("#") }
        if !commandLines.isEmpty && commandLines.count <= 40 {
            var allCommands = true
            var continuation = false
            for line in commandLines {
                defer { continuation = line.hasSuffix("\\") }
                if continuation { continue }
                let first = line.split(separator: " ").first.map(String.init) ?? line
                let word = first.contains("=") && !first.hasPrefix("-") ? "export" : first
                if !shellCommands.contains(word) && !word.hasPrefix("./") { allCommands = false; break }
            }
            if allCommands { return lang("bash") }
        }

        var scores: [String: Double] = [:]
        func add(_ id: String, _ value: Double) { scores[id, default: 0] += value }

        for line in lines {
            let lower = line.lowercased()
            // Python
            if line.hasPrefix("def ") && line.hasSuffix(":") { add("python", 3) }
            if line.hasPrefix("from ") && line.contains(" import ") { add("python", 3) }
            if line.hasPrefix("import ") && !line.contains(";") && !line.contains("\"") && !line.contains("'") && !line.contains("{") {
                let module = line.dropFirst(7)
                if module.first?.isLowercase == true { add("python", 1.5); add("go", 0.5) } else { add("swift", 1.5) }
            }
            if line.hasPrefix("elif ") || line.hasPrefix("except") || line == "else:" || line.hasPrefix("with ") && line.hasSuffix(":") { add("python", 3) }
            if line.hasPrefix("class ") && line.hasSuffix(":") { add("python", 3) }
            if line.contains("self.") { add("python", 1); add("ruby", 0.2) }
            if line.hasPrefix("if __name__") { add("python", 6) }
            if line.hasPrefix("print(") { add("python", 1) }
            if line.hasPrefix("@") && !line.contains("(") && !line.contains(" ") { add("python", 0.5); add("java", 0.5); add("swift", 0.5) }
            // JavaScript / TypeScript
            if (line.hasPrefix("const ") || line.hasPrefix("let ")) && line.contains(" = ") { add("javascript", 1.5) }
            if line.hasPrefix("function ") || line.hasPrefix("async function ") || line.hasPrefix("export function ") { add("javascript", 2) }
            if line.contains("=> ") || line.hasSuffix("=>") || line.contains("=> {") { add("javascript", 1.5) }
            if line.contains("console.log(") || line.contains("document.") || line.contains("window.") { add("javascript", 3) }
            if line.contains("require(") && line.contains("const ") { add("javascript", 3) }
            if line.hasPrefix("import ") && (line.contains(" from '") || line.contains(" from \"")) { add("javascript", 4) }
            if line.hasPrefix("export default") || line.hasPrefix("export const") || line.hasPrefix("module.exports") { add("javascript", 3) }
            if line.hasPrefix("interface ") && line.hasSuffix("{") { add("typescript", 3); add("javascript", 1) }
            if line.hasPrefix("type ") && line.contains(" = ") { add("typescript", 3); add("javascript", 1) }
            if line.contains(": string") || line.contains(": number") || line.contains(": boolean") || line.contains("<string>") { add("typescript", 2) }
            if line.contains("useState(") || line.contains("className=") || line.contains("return (") && sample.contains("</") { add("jsx", 2) }
            // Swift
            if line.hasPrefix("import SwiftUI") || line.hasPrefix("import Foundation") || line.hasPrefix("import UIKit") || line.hasPrefix("import AppKit") { add("swift", 6) }
            if line.hasPrefix("func ") || line.contains(" func ") { add("swift", 2); add("go", 1.5) }
            if line.hasPrefix("guard ") || line.hasPrefix("if let ") || line.contains("some View") { add("swift", 4) }
            if line.hasPrefix("@State") || line.hasPrefix("@Published") || line.hasPrefix("@MainActor") || line.hasPrefix("@Observable") { add("swift", 4) }
            if (line.hasPrefix("let ") || line.hasPrefix("var ")) && line.contains(": ") && !line.hasSuffix(";") { add("swift", 1) }
            // Go
            if line.hasPrefix("package ") && !line.hasSuffix(";") && line.split(separator: " ").count == 2 { add("go", 4); add("kotlin", 1.5) }
            if line.contains(" := ") { add("go", 3) }
            if line.hasPrefix("func (") || line.contains("fmt.") || line.contains("err != nil") { add("go", 4) }
            // Rust
            if line.hasPrefix("fn ") || line.hasPrefix("pub fn ") || line.hasPrefix("async fn ") || line.hasPrefix("pub async fn ") { add("rust", 4) }
            if line.contains("let mut ") || line.hasPrefix("use std::") || line.hasPrefix("use crate::") || line.hasPrefix("impl ") || line.hasPrefix("#[derive") { add("rust", 4) }
            if line.contains("println!(") || line.contains("vec![") || line.contains("::new(") && line.hasSuffix(";") && line.contains("let ") { add("rust", 2) }
            // Java / Kotlin / C#
            if line.hasPrefix("public class ") || line.contains("public static void main") || line.contains("System.out.") || line.hasPrefix("import java.") { add("java", 4) }
            if line.hasPrefix("@Override") || (line.hasPrefix("private final ") && line.hasSuffix(";")) { add("java", 2) }
            if line.hasPrefix("fun ") || line.hasPrefix("val ") || line.hasPrefix("data class ") || line.hasPrefix("import kotlin") || line.hasPrefix("import androidx") { add("kotlin", 3) }
            if line.hasPrefix("using System") || line.contains("Console.Write") || line.contains("{ get; set; }") || line.hasPrefix("namespace ") && !line.contains("::") { add("csharp", 4) }
            if line.hasPrefix("public async Task") || line.contains("async Task<") { add("csharp", 3) }
            // C / C++ / Objective-C
            if line.hasPrefix("#include <") || line.hasPrefix("#include \"") {
                if line.contains("iostream") || line.contains("vector") || line.contains("string>") || line.hasSuffix("pp>") || line.contains("memory>") { add("cpp", 5) } else { add("c", 3); add("cpp", 2) }
            }
            if line.contains("std::") || line.contains("cout <<") || line.hasPrefix("template <") || line.hasPrefix("template<") || line == "public:" || line == "private:" { add("cpp", 4) }
            if line.hasPrefix("int main(") || line.contains("printf(") || line.contains("malloc(") { add("c", 2); add("cpp", 1) }
            if line.hasPrefix("#import ") || line.hasPrefix("@interface") || line.hasPrefix("@implementation") || line.contains("NSString") { add("objectivec", 5) }
            // Ruby
            if line.hasPrefix("puts ") || line.contains(".each do |") || line.contains(" do |") || line.hasPrefix("attr_accessor") || line.hasPrefix("require '") { add("ruby", 4) }
            if line.hasPrefix("def ") && !line.hasSuffix(":") && !line.contains("{") { add("ruby", 2); add("elixir", 0.5) }
            if line == "end" { add("ruby", 1.5); add("lua", 1); add("elixir", 1) }
            // PHP
            if line.contains("$this->") || line.hasPrefix("echo $") || line.hasPrefix("namespace App") { add("php", 5) }
            // SQL
            for keyword in ["select ", "insert into ", "update ", "delete from ", "create table ", "alter table ", "drop table ", "with ", "create index ", "create view "] where lower.hasPrefix(keyword) {
                add("sql", keyword == "with " || keyword == "update " ? 1.5 : 4)
            }
            if lower.hasPrefix("from ") || lower.hasPrefix("where ") || lower.hasPrefix("join ") || lower.hasPrefix("left join ") || lower.hasPrefix("group by ") || lower.hasPrefix("order by ") { add("sql", 2) }
            // Shell
            if line.hasPrefix("if [") || line == "fi" || line == "done" || line == "esac" || line.hasPrefix("for ") && line.hasSuffix("; do") { add("bash", 4) }
            if line.hasPrefix("export ") || line.hasPrefix("echo ") || line.hasPrefix("sudo ") { add("bash", 2) }
            // PowerShell
            if line.contains("Write-Host") || line.contains("$env:") || line.hasPrefix("Get-") || line.hasPrefix("Set-") || line.hasPrefix("New-") || line.contains("-ErrorAction") { add("powershell", 4) }
            // Data & config
            if line.hasPrefix("[") && line.hasSuffix("]") && !line.contains(",") && !line.contains("\"") { add("toml", 2); add("ini", 1.8) }
            if isTOMLAssignment(line) { add("toml", 1.5) }
            if isEnvAssignment(line) { add("ini", 1); add("dotenv", 1.2) }
            if isYAMLKeyLine(line) && !line.hasSuffix(";") && !line.hasSuffix("{") && !line.hasSuffix(",") { add("yaml", 1.2) }
            if line.hasPrefix("- ") { add("yaml", 0.4); add("markdown", 0.4) }
            // CSS
            if isCSSSelectorLine(line) { add("css", 2) }
            if isCSSDeclarationLine(line) { add("css", 1.5) }
            if line.hasPrefix("@media") || line.hasPrefix("@import") || line.hasPrefix("@keyframes") { add("css", 3) }
            // Markdown
            if line.hasPrefix("## ") || line.hasPrefix("### ") { add("markdown", 3) }
            if line.hasPrefix("# ") { add("markdown", 1) }
            if line.contains("](") && line.contains("[") { add("markdown", 2) }
            if line.hasPrefix("```") { add("markdown", 4) }
            if line.hasPrefix("**") || line.hasPrefix("> ") { add("markdown", 1) }
            // Others
            if line.hasPrefix("local ") || line.contains("~=") && !line.contains("==") { add("lua", 2) }
            if line.contains(" <- ") || line.hasPrefix("library(") || line.contains("%>%") { add("r", 4) }
            if line.hasPrefix("defmodule ") || line.contains("|> ") && line.contains("Enum.") || line.hasPrefix("IO.puts") { add("elixir", 5) }
            if line.hasPrefix("module ") && line.hasSuffix(" where") || line.hasPrefix("import qualified") || line.contains(" :: ") && line.contains("->") { add("haskell", 4) }
            if line.hasPrefix("resource \"") || line.hasPrefix("provider \"") || line.hasPrefix("variable \"") || line.hasPrefix("module \"") { add("terraform", 5) }
            if line.hasPrefix("\\documentclass") || line.hasPrefix("\\begin{") || line.hasPrefix("\\usepackage") || line.hasPrefix("\\section") { add("latex", 5) }
            if line.hasPrefix("my $") || line.hasPrefix("use strict") || line.hasPrefix("use warnings") { add("perl", 5) }
            if line.hasPrefix("server {") || line.hasPrefix("location ") || line.hasPrefix("listen ") || line.hasPrefix("proxy_pass ") { add("nginx", 3) }
            if line.hasPrefix(".PHONY") || line.contains("$(CC)") || line.contains("$@") && line.hasPrefix("\t") { add("makefile", 5) }
            if line.hasPrefix("syntax = \"proto") || line.hasPrefix("message ") && line.hasSuffix("{") { add("protobuf", 3) }
            if line.hasPrefix("query ") || line.hasPrefix("mutation ") || line.hasPrefix("type Query") { add("graphql", 3) }
            if line.hasPrefix("cmake_minimum_required") || line.hasPrefix("add_executable(") || line.hasPrefix("target_link_libraries(") { add("cmake", 6) }
            if line.hasPrefix("import 'package:") || line.contains("Widget build(") { add("dart", 6) }
            if line.hasPrefix("object ") && line.contains("extends App") || line.hasPrefix("case class ") { add("scala", 5) }
            if line.hasPrefix("pragma solidity") || line.hasPrefix("contract ") { add("solidity", 6) }
        }

        // Structural penalties.
        if sample.contains(";\n") || sample.hasSuffix(";") {
            scores["python", default: 0] -= 1.5
            scores["yaml", default: 0] -= 2
            scores["ruby", default: 0] -= 1
        }
        if sample.contains("{") && sample.contains("}") { scores["yaml", default: 0] -= 1.5; scores["python", default: 0] -= 0.5 }
        if scores["yaml", default: 0] > 0 && Double(lines.count) > 0 && scores["yaml", default: 0] < Double(lines.count) * 0.45 { scores["yaml"] = 0 }
        if scores["toml", default: 0] > 0 && !lines.contains(where: { $0.hasPrefix("[") }) { scores["toml", default: 0] -= 1.5 }
        if scores["ini", default: 0] > 0 && !lines.contains(where: { $0.hasPrefix("[") }) {
            scores["ini"] = 0
        } else {
            scores["dotenv"] = 0
        }
        if (scores["dotenv"] ?? 0) > 0 && Double(lines.filter({ $0.contains("=") || $0.hasPrefix("#") }).count) < Double(lines.count) * 0.9 { scores["dotenv"] = 0 }
        if (scores["typescript"] ?? 0) > 0 { scores["typescript", default: 0] += scores["javascript", default: 0] * 0.6 }
        if (scores["jsx"] ?? 0) > 0 && sample.contains("</") { scores["jsx", default: 0] += scores["javascript", default: 0] }
        if (scores["jsx"] ?? 0) > 0 && (scores["typescript"] ?? 0) >= 2 { scores["tsx"] = scores["jsx", default: 0] + scores["typescript", default: 0] }

        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 4 else { return nil }
        let runnerUp = ranked.dropFirst().first?.value ?? 0
        guard best.value - runnerUp >= 2 || best.value >= runnerUp * 1.8 else { return nil }
        return lang(best.key)
    }

    static func keyPrefix(_ line: Substring, allowQuotes: Bool) -> Substring.Index {
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            guard c.isLetter || c.isNumber || c == "_" || c == "." || c == "-" || (allowQuotes && (c == "\"" || c == "'")) else { break }
            index = line.index(after: index)
        }
        return index
    }

    /// `key = "value"` / `key = 1` / `key = [` / `key = true` (TOML-style).
    static func isTOMLAssignment(_ line: String) -> Bool {
        let s = Substring(line)
        let end = keyPrefix(s, allowQuotes: false)
        guard end > s.startIndex, s[end...].hasPrefix(" = ") else { return false }
        let value = s[end...].dropFirst(3)
        guard let first = value.first else { return false }
        return first == "\"" || first.isNumber || first == "[" || first == "{" || value.hasPrefix("true") || value.hasPrefix("false")
    }

    /// `KEY=value` without spaces (INI / .env).
    static func isEnvAssignment(_ line: String) -> Bool {
        let s = Substring(line)
        let end = keyPrefix(s, allowQuotes: false)
        guard end > s.startIndex, end < s.endIndex, s[end] == "=" else { return false }
        return !line.contains(" ") && !s[s.index(after: end)...].contains("=")
    }

    /// `key: value`, `key:` or `- key: value`.
    static func isYAMLKeyLine(_ line: String) -> Bool {
        var s = Substring(line)
        if s.hasPrefix("- ") { s = s.dropFirst(2) }
        let end = keyPrefix(s, allowQuotes: true)
        guard end > s.startIndex, end < s.endIndex, s[end] == ":" else { return false }
        let after = s.index(after: end)
        return after == s.endIndex || s[after] == " "
    }

    static func isCSSSelectorLine(_ line: String) -> Bool {
        guard line.hasSuffix("{"), let first = line.first else { return false }
        guard first == "." || first == "#" || first == "@" || first == ":" || first == "[" || first.isLetter || first == "*" else { return false }
        return !line.contains("=") && !line.contains("(") && !line.contains(";") && line.dropLast().allSatisfy { $0 != "{" && $0 != "}" }
    }

    static func isCSSDeclarationLine(_ line: String) -> Bool {
        guard line.hasSuffix(";"), let colon = line.firstIndex(of: ":") else { return false }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ ($0.isLetter && $0.isLowercase) || $0 == "-" }) else { return false }
        let value = line[line.index(after: colon)...].dropLast()
        return !value.trimmingCharacters(in: .whitespaces).isEmpty && !value.contains(";")
    }

    static func detectJSON(_ trimmed: Substring) -> SyntaxLanguage? {
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        let rest = trimmed.dropFirst().drop(while: { $0.isWhitespace })
        guard let second = rest.first else { return nil }
        if first == "{" {
            guard second == "\"" || second == "}" else { return nil }
            if second == "\"" {
                let afterKey = rest.dropFirst().drop(while: { $0 != "\"" }).dropFirst().drop(while: { $0.isWhitespace })
                guard afterKey.first == ":" else { return nil }
            }
            return SyntaxLanguageRegistry.language(id: "json")
        }
        if second == "[" {
            let third = rest.dropFirst().drop(while: { $0.isWhitespace }).first
            if let third, third.isLetter { return nil } // TOML array table `[[x]]`
        }
        if second == "{" || second == "\"" || second == "[" || second == "]" || second.isNumber || second == "-" || rest.hasPrefix("true") || rest.hasPrefix("false") || rest.hasPrefix("null") {
            // Python lists of strings look like JSON too; that's fine.
            return SyntaxLanguageRegistry.language(id: "json")
        }
        return nil
    }
}
