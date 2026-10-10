# Ticket PDF fonts

The PDF embeds and subsets these bundled SIL Open Font License 1.1 fonts.
Noto Sans covers Latin/Chamorro text; Noto Sans JP provides Japanese fallback;
Noto Emoji provides monochrome emoji, including supplementary-plane ticket
symbols and variation selectors. The original UTF-8 strings are passed through
without stripping, transliteration, HTML parsing, or substitution of access data.
Japanese and emoji fallback use regular outlines for both text styles.

Copyright notices are retained inside the fonts and accompanying OFL files.
Noto Sans JP: © 2014–2021 Adobe, reserved font name “Source”.
Noto Emoji: Copyright 2013 Google LLC. Noto Sans: Copyright Google Inc.
No reserved font name was introduced by deriving static instances.

Downloaded 2026-10-11 from the official repositories below. Japanese and emoji
sources were converted to static weight 400 with fontTools 4.60.1:
`instantiateVariableFont(TTFont(source), {"wght": 400}, inplace=True).save(target)`.
No characters were removed; fontTools is a build-time tool, not a runtime dependency.
The bundled full fonts avoid relying on the host OS or external font downloads.

| Bundled file | SHA-256 | Official source |
| --- | --- | --- |
| NotoSans-Regular.ttf | `b85c38ecea8a7cfb39c24e395a4007474fa5a4fc864f6ee33309eb4948d232d5` | https://raw.githubusercontent.com/notofonts/noto-fonts/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf |
| NotoSans-Bold.ttf | `c976e4b1b99edc88775377fcc21692ca4bfa46b6d6ca6522bfda505b28ff9d6a` | https://raw.githubusercontent.com/notofonts/noto-fonts/main/hinted/ttf/NotoSans/NotoSans-Bold.ttf |
| NotoSansJP-Regular.ttf | `a41f18fd6511294909e8ed3959634da35970503332d1678b31417e6aa1f15006` | https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/Variable/TTF/Subset/NotoSansJP-VF.ttf |
| NotoEmoji-Regular.ttf | `df63761b7ea9b81e59004c86054c1c1db2c9203815d58c2a0b2e4d8cc8eeb424` | https://raw.githubusercontent.com/google/fonts/main/ofl/notoemoji/NotoEmoji%5Bwght%5D.ttf |

The fallback stack covers these supported languages and tested emoji, rather than claiming every Unicode script or complex emoji sequence. Unsupported code points fail before PDF/QR creation with a code-point-only error, rather than silently printing missing-glyph boxes. Complex emoji shaping and other scripts are not promised. Font updates must repeat actual extraction and raster checks, including long metadata and the complete admission QR/footer block.
