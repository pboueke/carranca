#!/usr/bin/env bash
# Build doc/page/index.html with embedded markdown for local and hosted viewing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/doc/page"
OUT_FILE="$OUT_DIR/index.html"
TMP_FILE="$(mktemp)"
CHANGELOG_FILE="$ROOT_DIR/doc/CHANGELOG.md"
REPO_BLOB_BASE="https://github.com/pboueke/carranca/blob/main"

VERSION="$(grep -m1 '^## [0-9]' "$CHANGELOG_FILE" 2>/dev/null | awk '{print $2}' || true)"
SOURCE_LABEL="source"
[ -n "$VERSION" ] && SOURCE_LABEL="${SOURCE_LABEL} ${VERSION}"

mkdir -p "$OUT_DIR"

html_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g'
}

emit_doc_section() {
  local id="$1"
  local title="$2"
  local desc="$3"
  local file="$4"
  local relative_file="${file#$ROOT_DIR/}"

  {
    printf '    <details id="doc-%s">\n' "$id"
    printf '      <summary>%s <span class="desc">%s</span></summary>\n' "$title" "$desc"
    printf '      <div class="doc-content" data-source-path="%s">\n' "$relative_file"
    printf '        <pre class="doc-markdown-static">'
    sed '1{/^# /d;}' "$file" | html_escape
    printf '</pre>\n'
    printf '      </div>\n'
    printf '    </details>\n\n'
  } >> "$TMP_FILE"
}

cat > "$TMP_FILE" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Carranca: Isolated agent runtime with reviewable evidence, deep observability, policy enforcement, and adversarial hardening</title>
  <meta name="description" content="Carranca is a local agent runtime for coding agents that adds workflow, policy, and audit controls on top of container execution." />
  <meta name="robots" content="index,follow,max-snippet:-1,max-image-preview:large,max-video-preview:-1" />
  <meta name="application-name" content="Carranca" />
  <meta name="keywords" content="Carranca, coding agent sandbox, agent runtime, containerized agent, tamper-evident logs, coding agent security, developer tooling, audit logging, policy enforcement, adversarial hardening" />
  <meta property="og:title" content="Carranca: Isolated agent runtime with reviewable evidence, deep observability, policy enforcement, and adversarial hardening" />
  <meta property="og:description" content="Local runtime for coding agents that adds workflow, policy, and audit controls on top of hardened container execution." />
  <meta property="og:type" content="website" />
  <meta property="og:site_name" content="Carranca" />
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:title" content="Carranca: Isolated agent runtime with reviewable evidence, deep observability, policy enforcement, and adversarial hardening" />
  <meta name="twitter:description" content="Local runtime for coding agents that adds workflow, policy, and audit controls on top of hardened container execution." />
  <script type="application/ld+json">
    {
      "@context": "https://schema.org",
      "@graph": [
        {
          "@type": "SoftwareSourceCode",
          "name": "Carranca",
          "codeRepository": "https://github.com/pboueke/carranca",
          "license": "https://github.com/pboueke/carranca/blob/main/LICENSE",
          "programmingLanguage": "Bash",
          "runtimePlatform": "Docker, Podman",
          "description": "Carranca is a local agent runtime for coding agents that adds workflow, policy, and audit controls on top of container execution."
        },
        {
          "@type": "TechArticle",
          "headline": "Carranca Technical Reference",
          "about": {
            "@type": "SoftwareSourceCode",
            "name": "Carranca"
          },
          "description": "Technical reference for Carranca covering architecture, configuration, usage, session logs, trust model, and changelog."
        }
      ]
    }
  </script>
  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
  <style>
    :root {
      --bg: #fafaf9;
      --fg: #1c1917;
      --muted: #78716c;
      --border: #d6d3d1;
      --accent: #292524;
      --code-bg: #f5f5f4;
      --link: #44403c;
      --details-bg: #ffffff;
      --shadow: rgba(0,0,0,0.04);
    }

    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1c1917;
        --fg: #e7e5e4;
        --muted: #a8a29e;
        --border: #44403c;
        --accent: #e7e5e4;
        --code-bg: #292524;
        --link: #d6d3d1;
        --details-bg: #292524;
        --shadow: rgba(0,0,0,0.2);
      }
    }

    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      font-family: "Iowan Old Style", "Palatino Linotype", "Book Antiqua", Palatino, "Noto Serif", "Times New Roman", serif;
      background: var(--bg);
      color: var(--fg);
      line-height: 1.6;
    }

    .hero {
      text-align: center;
      padding: 3rem 1.5rem 2rem;
      max-width: 1200px;
      margin: 0 auto;
    }

    .hero img {
      width: 100%;
      max-width: 560px;
      border-radius: 6px;
      margin-bottom: 0.5rem;
    }

    .hero .caption {
      font-size: 0.8rem;
      color: var(--muted);
      font-style: italic;
      margin-bottom: 1.5rem;
    }

    .hero h1 {
      font-size: 2.4rem;
      font-weight: 700;
      letter-spacing: -0.02em;
      margin-bottom: 0.75rem;
    }

    .hero .tagline {
      font-size: 1.1rem;
      color: var(--muted);
      max-width: 800px;
      margin: 0 auto 1.5rem;
    }

    .hero .links {
      margin-top: 1rem;
      font-size: 0.95rem;
    }

    .hero .links a {
      color: var(--link);
      text-decoration: underline;
      text-underline-offset: 3px;
    }

    .docs {
      max-width: 1200px;
      margin: 0 auto;
      padding: 0 1.5rem 4rem;
    }

    .docs h2 {
      font-size: 1.3rem;
      font-weight: 600;
      margin-bottom: 1rem;
      color: var(--muted);
      letter-spacing: 0.02em;
    }

    .docs-intro {
      color: var(--muted);
      margin: 0 0 1.25rem;
    }

    details {
      border: 1px solid var(--border);
      border-radius: 6px;
      margin-bottom: 0.75rem;
      background: var(--details-bg);
      box-shadow: 0 1px 2px var(--shadow);
    }

    summary {
      padding: 0.85rem 1.1rem;
      cursor: pointer;
      font-weight: 600;
      font-size: 1.05rem;
      list-style: none;
      display: flex;
      align-items: center;
      gap: 0.6rem;
      user-select: none;
    }

    summary::-webkit-details-marker { display: none; }

    summary::before {
      content: "\25B6";
      font-size: 0.7rem;
      transition: transform 0.15s ease;
      flex-shrink: 0;
    }

    details[open] > summary::before {
      transform: rotate(90deg);
    }

    summary .desc {
      font-weight: 400;
      font-size: 0.88rem;
      color: var(--muted);
      margin-left: auto;
    }

    .doc-content {
      padding: 0.25rem 1.5rem 1.5rem;
      border-top: 1px solid var(--border);
    }

    .doc-content h1 { font-size: 1.5rem; margin: 1.25rem 0 0.5rem; font-weight: 700; }
    .doc-content h2 { font-size: 1.25rem; margin: 1.5rem 0 0.5rem; font-weight: 600; color: var(--fg); letter-spacing: 0; }
    .doc-content h3 { font-size: 1.05rem; margin: 1.25rem 0 0.4rem; font-weight: 600; }
    .doc-content p { margin: 0.6rem 0; }
    .doc-content ul, .doc-content ol { margin: 0.5rem 0 0.5rem 1.5rem; }
    .doc-content li { margin: 0.25rem 0; }

    .doc-content code {
      font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
      font-size: 0.88em;
      background: var(--code-bg);
      padding: 0.15em 0.35em;
      border-radius: 3px;
    }

    .doc-content pre {
      background: var(--code-bg);
      padding: 1rem;
      border-radius: 5px;
      overflow-x: auto;
      margin: 0.75rem 0;
      line-height: 1.5;
    }

    .doc-content pre code {
      background: none;
      padding: 0;
      font-size: 0.85em;
    }

    .doc-content table {
      width: 100%;
      border-collapse: collapse;
      margin: 0.75rem 0;
      font-size: 0.92rem;
    }

    .doc-content th, .doc-content td {
      border: 1px solid var(--border);
      padding: 0.45rem 0.65rem;
      text-align: left;
    }

    .doc-content th {
      background: var(--code-bg);
      font-weight: 600;
    }

    .doc-content a {
      color: var(--link);
      text-decoration: underline;
      text-underline-offset: 2px;
    }

    .doc-content hr {
      border: none;
      border-top: 1px solid var(--border);
      margin: 1.5rem 0;
    }

    .doc-content del { opacity: 0.5; }

    .doc-content blockquote {
      border-left: 3px solid var(--border);
      padding-left: 1rem;
      color: var(--muted);
      margin: 0.75rem 0;
    }

    .doc-markdown-static {
      white-space: pre-wrap;
      word-break: break-word;
      font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
      font-size: 0.92rem;
      line-height: 1.6;
      background: var(--code-bg);
      padding: 1rem;
      border-radius: 5px;
      margin-top: 0.75rem;
    }

    footer {
      text-align: center;
      padding: 2rem 1rem;
      color: var(--muted);
      font-size: 0.85rem;
      border-top: 1px solid var(--border);
      max-width: 1200px;
      margin: 0 auto;
    }

    footer a { color: var(--link); }
  </style>
</head>
<body>
  <div class="hero">
    <img src="carranca.jpg" alt="A Carranca figurehead on a boat" />
    <p class="caption">A Carranca photographed by Marcel Gautherot in 1946. Instituto Moreira Salles collection.</p>
    <h1>Carranca</h1>
    <p class="tagline">
      Isolated agent runtime with reviewable evidence, deep observability, policy enforcement, and adversarial hardening.
      Named after the carved figureheads on boats in Brazil's S&atilde;o Francisco river,
      believed to protect sailors. Carranca protects engineers from coding agents
      by running them in hardened containers with tamper-evident logs, kernel-level tracing,
      enforceable guardrails, and forgery detection.
    </p>
    <div class="links">
      <a href="https://github.com/pboueke/carranca">__SOURCE_LABEL__</a>
    </div>
  </div>

  <div class="docs">
    <h2>Technical Reference</h2>
    <p class="docs-intro">
      This page is the primary technical reference for Carranca. It combines the
      current architecture, configuration schema, CLI usage, session log format,
      trust model, roadmap, versioning policy, and changelog in one browsable
      document.
    </p>

EOF

emit_doc_section "objective" "Objective" "Who Carranca is for, who it is not for, and how it differs from other sandbox models" "$ROOT_DIR/doc/objective.md"
emit_doc_section "architecture" "Architecture" "Container layout, data flow, and session lifecycle" "$ROOT_DIR/doc/architecture.md"
emit_doc_section "configuration" "Configuration" "Complete .carranca.yml reference" "$ROOT_DIR/doc/configuration.md"
emit_doc_section "usage" "Usage" "Detailed command line reference and operator workflows" "$ROOT_DIR/doc/usage.md"
emit_doc_section "ci" "CI/CD Integration" "Headless execution, exit codes, session artifacts, and automated PR review" "$ROOT_DIR/doc/ci.md"
emit_doc_section "session-log" "Session Log Format" "JSONL schema, event types, and HMAC chain" "$ROOT_DIR/doc/session-log.md"
emit_doc_section "trust-model" "Trust Model" "Security boundaries and failure behavior" "$ROOT_DIR/doc/trust-model.md"
emit_doc_section "faq" "FAQ" "Design choices, trust assumptions, and common objections" "$ROOT_DIR/doc/faq.md"
emit_doc_section "changelog" "Changelog" "Release history and version source of truth" "$ROOT_DIR/doc/CHANGELOG.md"

cat >> "$TMP_FILE" <<'EOF'
  </div>

  <footer>
    <a href="https://github.com/pboueke/carranca">Carranca</a> is MIT-licensed.
  </footer>

  <script>
    const repoBlobBase = '__REPO_BLOB_BASE__';

    function hasExternalScheme(href) {
      return /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(href);
    }

    function resolveRelativeDocPath(sourcePath, href) {
      const [rawPath, rawHash = ''] = href.split('#');
      if (!rawPath) {
        return null;
      }

      const sourceParts = sourcePath.split('/');
      sourceParts.pop();

      rawPath.split('/').forEach(part => {
        if (!part || part === '.') {
          return;
        }
        if (part === '..') {
          if (sourceParts.length > 0) {
            sourceParts.pop();
          }
          return;
        }
        sourceParts.push(part);
      });

      return {
        path: sourceParts.join('/'),
        hash: rawHash ? `#${rawHash}` : ''
      };
    }

    document.querySelectorAll('.doc-content').forEach(container => {
      const source = container.querySelector('.doc-markdown-static');
      if (!source) return;

      const md = source.textContent || "";
      const sourcePath = container.dataset.sourcePath || "";
      if (window.marked && typeof window.marked.parse === "function") {
        const rendered = document.createElement('div');
        rendered.className = 'doc-rendered';
        rendered.innerHTML = window.marked.parse(md);
        rendered.querySelectorAll('a[href]').forEach(link => {
          const href = link.getAttribute('href');
          if (!href || href.startsWith('#') || hasExternalScheme(href)) return;

          const cleanHref = href.replace(/^\.\//, '');
          if (!/\.md(?:#.*)?$/.test(cleanHref)) return;

          const resolved = resolveRelativeDocPath(sourcePath, cleanHref);
          if (!resolved || !resolved.path) return;

          link.setAttribute('href', `${repoBlobBase}/${resolved.path}${resolved.hash}`);
        });
        source.style.display = 'none';
        container.appendChild(rendered);
      }
    });
  </script>

</body>
</html>
EOF

sed -i "s|__SOURCE_LABEL__|$SOURCE_LABEL|g" "$TMP_FILE"
sed -i "s|__REPO_BLOB_BASE__|$REPO_BLOB_BASE|g" "$TMP_FILE"

mv "$TMP_FILE" "$OUT_FILE"
chmod 0644 "$OUT_FILE"
echo "doc-page: built $OUT_FILE"
