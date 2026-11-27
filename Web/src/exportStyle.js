// Stylesheet for Print, Export as PDF and Export as HTML when no Typora theme is selected.
// Same look as Nib's own reading view, light only (paper is white), sized for A4 when printed.
export const EXPORT_CSS = `
:root { color-scheme: light; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
html { -webkit-text-size-adjust: 100%; }
body { margin: 0; background: #fff; color: #1d1d1f;
  font: 16px/1.75 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", sans-serif;
  -webkit-font-smoothing: antialiased; }
#write { max-width: 760px; margin: 0 auto; padding: 48px 40px 64px; letter-spacing: -0.006em; }
#write > :first-child { margin-top: 0; }
h1, h2, h3, h4, h5, h6 { line-height: 1.3; font-weight: 700; margin: 1.6em 0 0.6em; break-after: avoid; }
h1 { font-size: 1.9em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; } h4 { font-size: 1.1em; }
h5, h6 { font-size: 1em; color: #424245; }
p { margin: 0 0 0.9em; }
a { color: #0071e3; text-decoration: none; }
strong { font-weight: 650; }
del { color: #6e6e73; }
ul, ol { margin: 0 0 0.9em; padding-left: 1.6em; }
li > p { margin: 0; }
ol ol { list-style-type: lower-alpha; }
ol ol ol { list-style-type: lower-roman; }
ol ol ol ol { list-style-type: decimal; }
li::marker { color: #0071e3; }
.task-list-item { list-style: none; }
.task-list-item > input { float: left; margin: 0.5em 0 0 -1.5em; }
.task-done { color: #6e6e73; text-decoration: line-through; }
blockquote { margin: 0 0 0.9em; padding: 0 1em; border-left: 3px solid #d2d2d7; color: #424245; }
hr { border: 0; border-top: 1px solid #d2d2d7; margin: 2em 0; }
img { max-width: 100%; }
code { font: 0.88em ui-monospace, "SF Mono", Menlo, monospace; background: rgba(0,0,0,0.045); padding: 0.1em 0.35em; border-radius: 5px; }
pre.md-fences { background: #f5f5f7; border-radius: 10px; padding: 12px 16px; margin: 0 0 1em; overflow-x: auto;
  font: 0.86em/1.6 ui-monospace, "SF Mono", Menlo, monospace; break-inside: avoid; }
pre.md-fences pre.CodeMirror-line { margin: 0; white-space: pre-wrap; font: inherit; }
.cm-keyword { color: #ad3da4; } .cm-string, .cm-string-2 { color: #c41a16; } .cm-comment { color: #707f8c; }
.cm-number, .cm-atom { color: #1c00cf; } .cm-type, .cm-variable-3, .cm-tag { color: #3e8087; }
.cm-def, .cm-variable-2, .cm-property, .cm-attribute { color: #4b21b0; }
figure.table-figure { margin: 0 0 1em; overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 0.92em; }
th, td { border: 1px solid #d2d2d7; padding: 6px 12px; text-align: left; vertical-align: top; }
th { background: #f5f5f7; font-weight: 600; }
tr { break-inside: avoid; }
pre.md-meta-block { display: none; }
@page { size: A4; margin: 18mm 16mm; }
@media print {
  #write { max-width: none; padding: 0; }
  a { color: inherit; }
}
`
