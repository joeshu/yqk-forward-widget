from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
import json
root=Path(__file__).resolve().parents[1]/'Resources/Assets.xcassets/AppIcon.appiconset'
root.mkdir(parents=True,exist_ok=True)
S=1024
im=Image.new('RGB',(S,S)); p=im.load()
for y in range(S):
 t=y/(S-1); c=(int(9+18*t),int(15+5*t),int(34+35*t))
 for x in range(S): p[x,y]=c
glow=Image.new('RGBA',(S,S)); d=ImageDraw.Draw(glow)
d.ellipse((145,110,890,855),fill=(61,85,255,90)); glow=glow.filter(ImageFilter.GaussianBlur(130)); im=Image.alpha_composite(im.convert('RGBA'),glow); d=ImageDraw.Draw(im)
# television frame and display
d.rounded_rectangle((185,260,839,752),radius=92,fill=(244,247,255,255))
d.rounded_rectangle((211,286,813,726),radius=72,fill=(16,25,52,255))
# inner live glow
d.rounded_rectangle((252,326,772,686),radius=48,fill=(19,47,83,255))
# play mark
d.polygon([(455,405),(455,607),(625,506)],fill=(255,65,112,255))
# antenna + stand
d.line((390,260,315,170),fill=(244,247,255,255),width=26); d.line((634,260,710,170),fill=(244,247,255,255),width=26)
d.rounded_rectangle((466,744,558,805),radius=20,fill=(244,247,255,255)); d.rounded_rectangle((372,792,652,830),radius=18,fill=(244,247,255,255))
# live indicator
d.ellipse((720,218,790,288),fill=(255,65,112,255))
im=im.convert('RGB')
entries=[]
def add(idiom,size,scale,pixels,name):
 fn=f'{name}.png'; im.resize((pixels,pixels),Image.Resampling.LANCZOS).save(root/fn,optimize=True)
 entries.append({'filename':fn,'idiom':idiom,'scale':scale,'size':size})
for idiom,sizes in [('iphone',[(20,2),(20,3),(29,2),(29,3),(40,2),(40,3),(60,2),(60,3)]),('ipad',[(20,1),(20,2),(29,1),(29,2),(40,1),(40,2),(50,1),(50,2),(76,1),(76,2),(83.5,2)])]:
 for pt,sc in sizes: add(idiom,f'{pt}x{pt}',f'{sc}x',round(pt*sc),f'{idiom}-{str(pt).replace(".","_")}@{sc}x')
add('ios-marketing','1024x1024','1x',1024,'marketing-1024')
(root/'Contents.json').write_text(json.dumps({'images':entries,'info':{'author':'xcode','version':1}},indent=2))
print('generated',len(entries),'icons at',root)
