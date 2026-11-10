#!/usr/bin/env python3
"""Extract Swift literals with interpolation boundaries; migrate display text once."""
from pathlib import Path
import re,json
ROOT=Path(__file__).resolve().parents[1]
def string(src,start):
 raw=0
 j=start-1
 while j>=0 and src[j]=='#':raw+=1;j-=1
 triple=src.startswith('"""',start); q='"""' if triple else '"'; i=start+len(q); parts=[]; args=[]; plain=''
 while i<len(src):
  if src.startswith(q+'#'*raw,i):return i+len(q)+raw,plain,args
  if src.startswith('\\'+'#'*raw+'(',i):
   depth=1;j=i+2+raw
   while depth:
    if src[j]=='"':j=string(src,j)[0];continue
    if src[j]=='(':depth+=1
    if src[j]==')':depth-=1
    j+=1
   plain+='%@';args.append(src[i+2+raw:j-1]);i=j;continue
  if src[i]=='\\' and i+1<len(src):
   c=src[i+1];plain+= {'n':'\n','t':'\t','r':'\r','"':'"','\\':'\\'}.get(c,'\\'+c);i+=2;continue
  plain+=src[i];i+=1
 raise ValueError('Unclosed string')
def literals(src):
 i=0
 while i<len(src):
  if src.startswith('//',i):i=src.find('\n',i) if '\n' in src[i:] else len(src);continue
  if src.startswith('/*',i):i=src.index('*/',i+2)+2;continue
  if src[i]=='"':
   end,key,args=string(src,i);yield i,end,key,args;i=end
  else:i+=1
if __name__ == '__main__':
 catalog=json.loads((ROOT/'Sources/ContextCore/Resources/Localizations.json').read_text())['en']
 errors=[]; count=0
 for p in sorted((ROOT/'Sources').rglob('*.swift')):
  if p.name.startswith('._') or p.name=='Localization.swift':continue
  src=p.read_text()
  for start,end,key,args in literals(src):
   if not src[:start].endswith('L('):continue
   if src.startswith('"""',start):
    import textwrap
    key=textwrap.dedent(key).strip('\n')
   count+=1
   if key not in catalog:errors.append((str(p.relative_to(ROOT)),src.count('\n',0,start)+1,key))
 print(json.dumps({'localized_calls':count,'missing_keys':errors},ensure_ascii=False,indent=2))
 raise SystemExit(bool(errors))
