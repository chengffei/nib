# Themes

A Nib theme is a single CSS file. Put it in the themes folder and pick it from **Settings › General › Theme**.

## Install a theme

1. Click **Themes Folder…** in **Settings › General**. The folder is `~/Library/Application Support/Nib/themes`.
2. Copy the theme's `.css` file into it. If the theme comes with a folder of the same name (fonts, images), copy that too.
3. Switch back to Nib. The theme is listed under **Custom** in the **Theme** menu.

Themes written for Typora use the same format and usually work as they are.

## Where a theme applies

| Mode | What the theme controls |
|---|---|
| Reading | The whole page. |
| Editing | Colours, fonts, headings, paragraphs, quotes, code blocks, tables and the spacing between blocks. Decorations drawn with `::before` / `::after` on list items are not shown. |
| Source | Background, text colour, link colour and fonts. |

The window follows the theme's background: a dark theme gets a dark window.

Scripts, raw HTML inside Markdown and styles for the app's own interface (sidebar, title bar, menus) are not used.

## Adjust a theme without editing it

Add these files to the themes folder. Nib loads them after the theme, so their rules win.

- `base.user.css` applies to every theme.
- `<theme name>.user.css` applies to one theme, for example `bear.user.css` for `bear.css`.

Example: more space between list items.

```css
#write li + li { margin-top: 0.5em; }
```

Changes show up when you switch back to Nib.

## Write a theme

Nib renders the document inside `#write`. Style these elements:

| Content | Selector |
|---|---|
| Page | `#write`; background and text colour from `--bg-color` and `--text-color` on `:root` |
| Headings, paragraphs | `h1` to `h6`, `p` |
| Lists | `ul`, `ol`, `li` (item text is wrapped in `p`); task items are `li.md-task-list-item` with an `input` checkbox |
| Quotes | `blockquote` |
| Code | inline `code`; blocks `pre.md-fences`, tokens `.cm-keyword`, `.cm-string`, `.cm-comment` and similar |
| Tables | `figure.table-figure > table` |
| Front matter | `pre.md-meta-block` |
| Links, images, rules | `a`, `img`, `hr` |

Set `--monospace` on `:root` to choose the code font. Relative `url()` and `@import` paths are resolved from the theme file, so fonts and images can sit in the theme's folder.
