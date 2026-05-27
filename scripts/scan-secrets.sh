#!/usr/bin/env bash
# scan-secrets.sh — Detect hardcoded secrets in tracked / staged / arbitrary files.
#
# Bash mirror of scripts/scan-secrets.ps1 — same modes, same exit codes,
# same JSON output shape. Use on CI, Linux, macOS where PowerShell isn't
# the default shell.
#
# Modes:
#   --mode staged   (default) — files staged for commit
#   --mode tracked          — every git-tracked file
#   --mode all              — tracked + untracked (respects .gitignore)
#   --mode paths -- a b c   — explicit file list
#
# Exit 0 if clean, exit 1 if any match. Emits JSON on stdout.

set -uo pipefail

MODE="staged"
EXPLICIT_PATHS=()

# ---------- Arg parse ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                EXPLICIT_PATHS+=("$1")
                shift
            done
            ;;
        *)
            EXPLICIT_PATHS+=("$1")
            shift
            ;;
    esac
done

case "$MODE" in
    staged|tracked|all|paths) ;;
    *)
        echo '{"error":"invalid --mode (use staged|tracked|all|paths)","status":"error"}' >&2
        exit 2
        ;;
esac

# ---------- Patterns (mirror scan-secrets.ps1) ----------
# Use POSIX ERE. Each pattern is tagged so the JSON report can name it.
declare -a SECRET_NAMES=(
    "JWT-shape"
    "Stripe-secret"
    "Stripe-publishable"
    "GitHub-PAT"
    "GitHub-OAuth"
    "GitHub-fine-grained"
    "GitLab-PAT"
    "Slack-bot"
    "Slack-user"
    "AWS-access-key"
    "AWS-temporary-key"
    "Google-API-key"
    "OpenAI-key"
    "Anthropic-key"
    "PostgreSQL-URL"
    "MongoDB-URL"
    "Generic-bearer-token"
    "Hex-near-secret-keyword"
    "Base64-near-secret-keyword"
    "Long-value-near-secret-keyword"
    "Generic-live-key-quoted"
    "Generic-test-key-quoted"
)

declare -a SECRET_PATTERNS=(
    'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    'sk_(live|test)_[A-Za-z0-9]{16,}'
    'pk_(live|test)_[A-Za-z0-9]{16,}'
    'ghp_[A-Za-z0-9]{30,}'
    'gho_[A-Za-z0-9]{30,}'
    'github_pat_[A-Za-z0-9_]{40,}'
    'glpat-[A-Za-z0-9_-]{16,}'
    'xoxb-[A-Za-z0-9-]{20,}'
    'xoxp-[A-Za-z0-9-]{20,}'
    'AKIA[A-Z0-9]{16}'
    'ASIA[A-Z0-9]{16}'
    'AIza[A-Za-z0-9_-]{35}'
    'sk-(proj-)?[A-Za-z0-9_-]{20,}'
    'sk-ant-(api|admin)[0-9]{2}-[A-Za-z0-9_-]{20,}'
    'postgres(ql)?://[^:[:space:]]+:[^@[:space:]]+@[^/[:space:]]+/[^[:space:]]+'
    'mongodb(\+srv)?://[^:[:space:]]+:[^@[:space:]]+@[^/[:space:]]+'
    '[Aa]uthorization:[[:space:]]*[Bb]earer[[:space:]]+[A-Za-z0-9._-]{20,}'
    '(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer|password|passwd|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][a-fA-F0-9]{32,}["'"'"']'
    '(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer|password|passwd|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9+/]{40,}={0,2}["'"'"']'
    '(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer|password|passwd|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9._+/=-]{30,}["'"'"']'
    '["'"'"'][A-Za-z0-9_-]{0,20}_live_[A-Za-z0-9]{20,}["'"'"']'
    '["'"'"'][A-Za-z0-9_-]{0,20}_test_[A-Za-z0-9]{20,}["'"'"']'
)

# Allow-list: any line matching one of these is treated as a placeholder.
ALLOW_RE='\$\{[A-Z_][A-Z0-9_]*\}|\$\{\{[^}]+\}\}|\{\{[A-Z_][A-Z0-9_]*\}\}|<REDACTED>|[Yy][Oo][Uu][Rr][-_]?([Aa][Pp][Ii][-_]?)?([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll])[-_]?[Hh][Ee][Rr][Ee]|[Ee][Xx][Aa][Mm][Pp][Ll][Ee][_-]?([Aa][Pp][Ii][_-]?)?([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt])|[Xx][Xx][Xx][_-]?([Tt][Ee][Ss][Tt]|[Ll][Ii][Vv][Ee]|[Pp][Rr][Oo][Dd]|[Dd][Ee][Vv])?[_-]?[Xx][Xx][Xx]|os\.environ|process\.env|getenv\(|config\.get\(|env\.[A-Z_][A-Z0-9_]*|<your[^>]+>|<api[^>]+>|<token[^>]+>|<secret[^>]+>|[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd]|[Pp][Ll][Aa][Cc][Ee][Hh][Oo][Ll][Dd][Ee][Rr]|[Ff][Aa][Kk][Ee][_-]?([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt])|[Dd][Uu][Mm][Mm][Yy][_-]?([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt])|[Ss][Aa][Mm][Pp][Ll][Ee][_-]?([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt])|sk-XXXX|sk_test_xxxxx|\.{3,}'

# Skip these files entirely.
SKIP_RE='\.lock$|package-lock\.json$|pnpm-lock\.yaml$|yarn\.lock$|composer\.lock$|Cargo\.lock$|Gemfile\.lock$|poetry\.lock$|uv\.lock$|\.min\.(js|css)$|\.bundle\.(js|css)$|\.(png|jpg|jpeg|gif|webp|svg|ico|woff|woff2|ttf|otf|eot|pdf|zip|tar|gz|tgz|bz2|7z|exe|dll|so|dylib|class|jar|pyc|pyo|whl|mp3|mp4|mov|avi)$|/node_modules/|/dist/|/build/|/\.next/|/\.venv/|/venv/|/__pycache__/|/target/|/vendor/|CHANGELOG\.md$|scan-secrets\.(ps1|sh)$|CODING_STANDARDS\.md$|yolo-honesty-checks\.md$'

# ---------- File enumeration ----------
collect_files() {
    case "$MODE" in
        staged)
            git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true
            ;;
        tracked)
            git ls-files 2>/dev/null || true
            ;;
        all)
            { git ls-files 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u
            ;;
        paths)
            printf '%s\n' "${EXPLICIT_PATHS[@]}"
            ;;
    esac
}

# ---------- Scan ----------
# Keep the shell wrapper for mode/file discovery, but do the expensive
# line/pattern matching in one Perl process. The previous nested Bash regex
# loop was too slow on the full tracked/all-file repository gate.
FILE_LIST_TMP="$(mktemp)"
PERL_SCAN_TMP="$(mktemp)"
cleanup_scan_tmp() {
    rm -f "$FILE_LIST_TMP" "$PERL_SCAN_TMP"
}
trap cleanup_scan_tmp EXIT

collect_files > "$FILE_LIST_TMP"

cat > "$PERL_SCAN_TMP" <<'PERL'
use strict;
use warnings;
use File::Temp qw();

my ($mode, $file_list_path) = @ARGV;

my @secret_patterns = (
    ["JWT-shape", qr/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/],
    ["Stripe-secret", qr/sk_(live|test)_[A-Za-z0-9]{16,}/],
    ["Stripe-publishable", qr/pk_(live|test)_[A-Za-z0-9]{16,}/],
    ["GitHub-PAT", qr/ghp_[A-Za-z0-9]{30,}/],
    ["GitHub-OAuth", qr/gho_[A-Za-z0-9]{30,}/],
    ["GitHub-fine-grained", qr/github_pat_[A-Za-z0-9_]{40,}/],
    ["GitLab-PAT", qr/glpat-[A-Za-z0-9_-]{16,}/],
    ["Slack-bot", qr/xoxb-[A-Za-z0-9-]{20,}/],
    ["Slack-user", qr/xoxp-[A-Za-z0-9-]{20,}/],
    ["AWS-access-key", qr/AKIA[A-Z0-9]{16}/],
    ["AWS-temporary-key", qr/ASIA[A-Z0-9]{16}/],
    ["Google-API-key", qr/AIza[A-Za-z0-9_-]{35}/],
    ["OpenAI-key", qr/sk-(proj-)?[A-Za-z0-9_-]{20,}/],
    ["Anthropic-key", qr/sk-ant-(api|admin)[0-9]{2}-[A-Za-z0-9_-]{20,}/],
    ["PostgreSQL-URL", qr{postgres(ql)?://[^:\s]+:[^@\s]+@[^/\s]+/[^\s]+}],
    ["MongoDB-URL", qr{mongodb(\+srv)?://[^:\s]+:[^@\s]+@[^/\s]+}],
    ["Generic-bearer-token", qr/[Aa]uthorization:\s*[Bb]earer\s+[A-Za-z0-9._-]{20,}/],
    ["Hex-near-secret-keyword", qr/(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer|password|passwd|client[_-]?secret)["']?\s*[:=]\s*["'][a-fA-F0-9]{32,}["']/i],
    ["Base64-near-secret-keyword", qr/(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer|password|passwd|client[_-]?secret)["']?\s*[:=]\s*["'][A-Za-z0-9+\/]{40,}={0,2}["']/i],
    ["Long-value-near-secret-keyword", qr/(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer|password|passwd|client[_-]?secret)["']?\s*[:=]\s*["'][A-Za-z0-9._+\/=-]{30,}["']/i],
    ["Generic-live-key-quoted", qr/["'][A-Za-z0-9_-]{0,20}_live_[A-Za-z0-9]{20,}["']/i],
    ["Generic-test-key-quoted", qr/["'][A-Za-z0-9_-]{0,20}_test_[A-Za-z0-9]{20,}["']/i],
);

my $allow_re = qr/\$\{[A-Z_][A-Z0-9_]*\}|\$\{\{[^}]+\}\}|\{\{[A-Z_][A-Z0-9_]*\}\}|<REDACTED>|your[-_]?(api[-_]?)?(key|token|secret|credential)[-_]?here|example[_-]?(api[_-]?)?(key|token|secret)|xxx[_-]?(test|live|prod|dev)?[_-]?xxx|os\.environ|process\.env|getenv\(|config\.get\(|env\.[A-Z_][A-Z0-9_]*|<your[^>]+>|<api[^>]+>|<token[^>]+>|<secret[^>]+>|redacted|placeholder|fake[_-]?(key|token|secret)|dummy[_-]?(key|token|secret)|sample[_-]?(key|token|secret)|sk-XXXX|sk_test_xxxxx|\.\.\./i;
my $skip_re = qr/\.lock$|package-lock\.json$|pnpm-lock\.yaml$|yarn\.lock$|composer\.lock$|Cargo\.lock$|Gemfile\.lock$|poetry\.lock$|uv\.lock$|\.min\.(js|css)$|\.bundle\.(js|css)$|\.(png|jpg|jpeg|gif|webp|svg|ico|woff|woff2|ttf|otf|eot|pdf|zip|tar|gz|tgz|bz2|7z|exe|dll|so|dylib|class|jar|pyc|pyo|whl|mp3|mp4|mov|avi)$|\/node_modules\/|\/dist\/|\/build\/|\/\.next\/|\/\.venv\/|\/venv\/|\/__pycache__\/|\/target\/|\/vendor\/|CHANGELOG\.md$|scan-secrets\.(ps1|sh)$|CODING_STANDARDS\.md$|yolo-honesty-checks\.md$/;

sub json_escape {
    my ($value) = @_;
    $value =~ s/\\/\\\\/g;
    $value =~ s/"/\\"/g;
    $value =~ s/\t/\\t/g;
    $value =~ s/\r/\\r/g;
    $value =~ s/\n/\\n/g;
    return $value;
}

open my $list_fh, '<', $file_list_path or die "cannot open file list: $!";
my @matches;
my $scanned = 0;

while (my $file = <$list_fh>) {
    chomp $file;
    next if $file eq '';
    next if !-f $file;
    next if $file =~ $skip_re;
    $scanned++;

    open my $fh, '<', $file or next;
    my $line_no = 0;
    while (my $line = <$fh>) {
        $line_no++;
        next if $line =~ /^\s*$/;
        next if $line =~ $allow_re;

        for my $entry (@secret_patterns) {
            my ($name, $pattern) = @$entry;
            if ($line =~ $pattern) {
                $line =~ s/\t/ /g;
                $line =~ s/^\s+//;
                $line =~ s/\s+$//;
                my $snippet = length($line) > 200 ? substr($line, 0, 200) . "..." : $line;
                push @matches, sprintf('{"file":"%s","line":%d,"pattern":"%s","snippet":"%s"}',
                    json_escape($file), $line_no, json_escape($name), json_escape($snippet));
                last;
            }
        }
    }
    close $fh;
}
close $list_fh;

my $status = @matches ? "secrets_detected" : "clean";
my $body = @matches ? "[" . join(",", @matches) . "]" : "[]";
print "{\n";
print "  \"matches\": $body,\n";
print "  \"files_scanned\": $scanned,\n";
print "  \"mode\": \"" . json_escape($mode) . "\",\n";
print "  \"status\": \"$status\"\n";
print "}\n";
exit(@matches ? 1 : 0);
PERL

perl "$PERL_SCAN_TMP" "$MODE" "$FILE_LIST_TMP"
