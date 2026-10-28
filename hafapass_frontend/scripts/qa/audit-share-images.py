from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from xml.sax.saxutils import escape
root=Path('hafapass_frontend')
def font(name, weight):
    f=TTFont(root/f'node_modules/@fontsource-variable/{name}/files/{name}-latin-wght-normal.woff2')
    return instantiateVariableFont(f, {'wght':weight}, inplace=True)
heading=font('space-grotesk',700)
body=font('plus-jakarta-sans',600)
def text(value,x,y,size,fill,f=heading):
    glyphs=f.getGlyphSet(); cmap=f.getBestCmap(); scale=size/f['head'].unitsPerEm; paths=[]
    for ch in value:
        g=cmap[ord(ch)]; pen=SVGPathPen(glyphs)
        glyphs[g].draw(TransformPen(pen,(scale,0,0,-scale,x,y)))
        paths.append(pen.getCommands()); x+=glyphs[g].width*scale
    return '<path fill="'+fill+'" d="'+' '.join(paths)+'"/>', x
for host in [False,True]:
    label='Sell tickets for your Guam event · 5% + $1 per paid ticket' if host else 'Events and tickets on Guam'
    parts=['<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630" role="img" aria-labelledby="title desc">',
      '<title id="title">HåfaPass</title><desc id="desc">'+escape(label)+'</desc>',
      '<!-- Lettering outlined from OFL Space Grotesk and Plus Jakarta Sans, bundled @fontsource-variable fonts. No external fonts. -->',
      '<rect width="1200" height="630" fill="#032827"/>',
      '<path d="M88 210H1112Q1136 210 1136 234V352a26 26 0 0 0 0 52v128q0 24-24 24H88q-24 0-24-24V404a26 26 0 0 0 0-52V234q0-24 24-24Z" fill="#faf8f2"/>',
      '<path d="M924 232V534" fill="none" stroke="#8eb7ad" stroke-width="2" stroke-dasharray="5 8"/>',
      '<rect x="84" y="180" width="96" height="8" rx="4" fill="#f27b69"/>']
    p,x=text('Håfa',84,141,76,'#ffffff'); parts.append(p)
    p,x=text('Pass',x,141,76,'#35c4b3');parts.append(p)
    if host:
        for s,y in [('Sell tickets for your',310),('Guam event',383)]:parts.append(text(s,108,y,62,'#032827')[0])
        parts.append(text('5% + $1 per paid ticket',108,470,32,'#284d49',body)[0])
    else:
        for s,y in [('Events and tickets',330),('on Guam',409)]:parts.append(text(s,108,y,70,'#032827')[0])
    parts.extend(['<g transform="translate(976 285) scale(4)" fill="none" stroke="#0e7c7b" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z"/><path d="M13 5v2m0 10v2m0-8v2"/></g>',
      '<g stroke="#032827" stroke-width="3"><path d="M981 437v41m8-41v41m7-41v41m12-41v41m6-41v41m12-41v41m9-41v41m7-41v41m10-41v41m8-41v41"/></g>', '</svg>'])
    (root/f'public/og-{"host" if host else "default"}.svg').write_text('\n'.join(parts)+'\n')
(root/'public/favicon.svg').write_text('''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#032827"/><g transform="translate(8 8) scale(2)" fill="none" stroke="#35c4b3" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z"/><path d="M13 5v2m0 10v2m0-8v2"/></g></svg>\n''')
