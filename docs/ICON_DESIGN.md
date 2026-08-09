# Microcam 图标设计

## 核心概念

应用主图标根据用户提供的视觉参考重新设计，而非复制原图。暖白色圆角底板中央由一个金色圆形镜头和两片向上展开的深灰、橙红色折页组成：镜头代表一天中被捕捉的活动片段，双页代表这些片段最终被整理为私人日记。

## 视觉语言

- 暖白色底板：保持轻盈、安静的桌面观感。
- 金黄色圆形：提供稳定的视觉焦点。
- 深灰与橙红色折页：形成平衡的双翼轮廓，并用折叠层次表达“汇集与整理”。
- 圆角方形外部为透明区域，符合 macOS Dock 与 Finder 的图标呈现方式。

## 菜单栏图标

菜单栏版本从主图标提炼出两个实心水滴形折页和一个圆形镜头，组成 18 × 18 pt 单色矢量模板。它省略材质、颜色和折叠阴影，只保留三部分轮廓；资产使用 template rendering，由 macOS 自动适配浅色、深色和高对比度菜单栏。

## 文件

- `docs/icon-design/microcam-appicon-master.png`：透明背景的生成式主稿。
- `Microcam/Assets.xcassets/AppIcon.appiconset`：macOS AppIcon 的 16–1024 px 输出。
- `Microcam/Assets.xcassets/MenuBarIcon.imageset`：菜单栏矢量模板。

## 处理方式

主图标使用内置 ImageGen 生成，用户图片仅作为配色、三部分构图和温和纸张质感的参考。生成源使用纯绿色外部工作底，本地移除后得到透明圆角主稿，再通过高质量缩放生成 16–1024 px 的 macOS AppIcon 全套尺寸。菜单栏图标为根据相同轮廓手工制作的确定性 SVG。

提示词要点：

> Original production macOS icon for Microcam, inspired by the reference but not copying its exact geometry: a warm ivory rounded-square body, a golden circular lens below two upward teardrop-shaped journal pages in charcoal and vermilion; minimal, softly dimensional, balanced, calm, privacy-friendly, and clearly legible at 16 px; no text, eyes, literal camera body, surveillance imagery, or watermark.
