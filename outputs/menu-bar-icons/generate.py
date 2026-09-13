from pathlib import Path
import math
import cairosvg

OUT = Path(__file__).resolve().parent
# Uniformly scaled curves follow the reference's broad, open crescent.
# A rounded outline preserves the hollow shape and soft tips at menu bar size.
MOON = '<path d="M10 6.6 C6 8.84 5.84 12.6 8.08 15.24 C10.64 18.28 15.12 17.56 17.28 13.96 C13.6 14.84 10.64 13.4 9.92 10.92 C9.36 9.32 9.6 7.64 10 6.6 Z" fill="none" stroke="currentColor" stroke-width="1.05" stroke-linecap="round" stroke-linejoin="round"/>'

def star(cx, cy, radius):
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = radius if i % 2 == 0 else radius * .43
        pts.append(f'{cx + math.cos(a)*r:.3f},{cy + math.sin(a)*r:.3f}')
    return '<polygon points="' + ' '.join(pts) + '"/>'

# Keep the side ornaments compact and clear of the crescent's outline.
STARS = star(3.7, 8.4, 1.8) + star(19.3, 9.1, 1.8) + star(3.8, 16.1, 1.35)
# Each note is 60% of the original size, with equal-width side footprints.
NOTE = '''<ellipse cx="0" cy="2" rx="1.65" ry="1.25" transform="rotate(-22 0 2)"/>
<path d="M1.35 1.7 V-4.7 Q3.35 -4.2 3.35 -2.1" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>'''
NOTES = f'<g transform="translate(2.8 12.45) scale(0.6)">{NOTE}</g><g transform="translate(19.5 12.45) scale(0.6)">{NOTE}</g>'
MOTION = '''<g fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round">
<path d="M2.9 9.7 L4.7 10.3 M2.3 12 H4.4 M2.9 14.3 L4.7 13.7"/>
<path d="M19.3 10.3 L21.1 9.7 M19.6 12 H21.7 M19.3 13.7 L21.1 14.3"/>
</g>'''
ICONS = {'nanight-default': MOON + STARS, 'nanight-sound': MOON + NOTES, 'nanight-motion': MOON + MOTION}

def svg(body, w=24, h=24):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{body}</svg>'

def render(source, target, size=None):
    w, h = map(int, size.split('x'))
    cairosvg.svg2png(url=str(source), write_to=str(target), output_width=w, output_height=h)

for name, body in ICONS.items():
    source = OUT / f'{name}.svg'
    source.write_text(svg(f'<g fill="currentColor" color="#000000">{body}</g>'))
    cairosvg.svg2pdf(url=str(source), write_to=str(OUT / f'{name}.pdf'), output_width=22, output_height=22)
    for scale in (1, 2, 3):
        render(source, OUT / f'{name}{"@"+str(scale)+"x" if scale > 1 else ""}.png', f'{22*scale}x{22*scale}')

parts = ['<rect width="960" height="640" fill="#f4f3ef"/>']
def text(x,y,label,size=16,color='#252733',weight=400):
    parts.append(f'<text x="{x}" y="{y}" font-family="Helvetica" font-size="{size}" font-weight="{weight}" fill="{color}">{label}</text>')
text(48,59,'Nanight',30,weight=600)
text(48,89,'Three states. One crescent.',16,color='#6b6d76')
for i, (name, body) in enumerate(ICONS.items()):
    x = 48 + i * 300
    parts.append(f'<rect x="{x}" y="120" width="264" height="266" rx="20" fill="#ffffff"/>')
    parts.append(f'<g transform="translate({x+72} 149) scale(5)" color="#252733" fill="currentColor">{body}</g>')
    text(x+24,320,['Default','Sound','Motion'][i],21,weight=600)
    text(x+24,351,['Tiny five-point stars','Music notes on each side','Motion lines on each side'][i],14,color='#6b6d76')
text(48,430,'ACTUAL SIZE · 22 PT',12,color='#6b6d76',weight=600)
for i,(name,body) in enumerate(ICONS.items()):
    x = 48+i*300
    for j,(bg,fg) in enumerate([('#ffffff','#252733'),('#252733','#ffffff')]):
        y=452+j*62
        parts.append(f'<rect x="{x}" y="{y}" width="264" height="48" rx="10" fill="{bg}"/>')
        parts.append(f'<g transform="translate({x+22} {y+13}) scale({22/24})" fill="currentColor" color="{fg}">{body}</g>')
        text(x+61,y+30,['Default','Sound','Motion'][i],13,color=fg)
text(48,609,'Vector concepts • transparent PNG exports at 1×, 2× and 3× • not installed in the app',13,color='#6b6d76')
preview = OUT / 'preview.svg'
preview.write_text(svg(''.join(parts),960,640))
render(preview, OUT / 'preview.png', '1920x1280')
print(OUT)
