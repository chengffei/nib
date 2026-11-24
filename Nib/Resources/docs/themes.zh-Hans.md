# 主题

Nib 的主题就是一个 CSS 文件。放进主题文件夹，在「设置 › 通用 › 主题」里选中即可。

## 安装主题

1. 在「设置 › 通用」里点「主题文件夹…」，位置是 `~/Library/Application Support/Nib/themes`。
2. 把主题的 `.css` 文件拷进去。主题如果带同名文件夹（字体、图片），一起拷进去。
3. 回到 Nib，主题出现在「主题」菜单的「自定义」分组里。

为 Typora 写的主题格式相同，一般可以直接使用。

## 主题在哪里生效

| 模式 | 主题控制的内容 |
|---|---|
| 阅读 | 整个页面。 |
| 编辑 | 颜色、字体、标题、段落、引用、代码块、表格和块间距。列表项上用 `::before` / `::after` 画的装饰不显示。 |
| 源码 | 底色、文字色、链接色和字体。 |

窗口深浅跟主题底色走，深色主题配深色窗口。

主题里的脚本、Markdown 中的原始 HTML、针对应用界面（侧栏、标题栏、菜单）的样式不生效。

## 不改原文件微调主题

在主题文件夹里加下面的文件，Nib 会在主题之后加载，规则优先。

- `base.user.css`：对所有主题生效。
- `主题名.user.css`：只对一个主题生效，如 `bear.css` 对应 `bear.user.css`。

例：列表项之间宽松一点。

```css
#write li + li { margin-top: 0.5em; }
```

回到 Nib 即生效。

## 编写主题

Nib 把文档渲染在 `#write` 里，给下面这些元素写样式：

| 内容 | 选择器 |
|---|---|
| 页面 | `#write`；底色和文字色取 `:root` 上的 `--bg-color`、`--text-color` |
| 标题、段落 | `h1` 至 `h6`、`p` |
| 列表 | `ul`、`ol`、`li`（项内文字包在 `p` 里）；任务项是带 `input` 勾选框的 `li.md-task-list-item` |
| 引用 | `blockquote` |
| 代码 | 行内 `code`；代码块 `pre.md-fences`，高亮用 `.cm-keyword`、`.cm-string`、`.cm-comment` 等 |
| 表格 | `figure.table-figure > table` |
| Front matter | `pre.md-meta-block` |
| 链接、图片、分隔线 | `a`、`img`、`hr` |

代码字体用 `:root` 上的 `--monospace` 指定。相对路径的 `url()` 和 `@import` 从主题文件所在位置找，字体和图片可以放在主题的同名文件夹里。
