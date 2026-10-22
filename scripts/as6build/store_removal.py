"""Remove in-app purchase, promotion and iPod music entry points from the menu movies.

Store movies keep every ActionScript-visible instance name, but the visible
store art, buttons and class registrations become empty clips, so the menus
work offline without purchase prompts. The pause-menu music button and the
sound-options playlist button are emptied the same way: the system music
library is not available to the game. Pure, deterministic byte transform.
"""
import hashlib
import struct

DEFINES = {2, 6, 7, 10, 11, 14, 20, 21, 22, 32, 33, 34, 35, 36, 37, 39, 46, 48, 60, 75, 83, 84, 87, 90, 91}


class Bits:
 def __init__(self,b,offset):self.b=b;self.bit=offset*8
 def read(self,n):
  v=0
  for i in range(n):v=v*2+((self.b[self.bit//8]>>(7-self.bit%8))&1);self.bit+=1
  return v
 def skip(self,n):self.bit+=n
 def end(self):return (self.bit+7)//8


def matrix(b,o):
 r=Bits(b,o)
 if r.read(1):r.skip(r.read(5)*2)
 if r.read(1):r.skip(r.read(5)*2)
 r.skip(r.read(5)*2);return r.end()

def cxform(b,o,alpha):
 r=Bits(b,o);a=r.read(1);m=r.read(1);n=r.read(4);r.skip((a+m)*n*(4 if alpha else 3));return r.end()

def cstr(b,o):
 e=b.index(0,o);return b[o:e].decode('utf-8','replace'),e+1

def place(code,b):
 if code==4:return None
 f=b[0];o=1;f2=0
 if code==70:f2=b[1];o=2
 depth=struct.unpack_from('<H',b,o)[0];o+=2
 if code==70 and ((f2&8) or ((f2&16) and (f&2))):_,o=cstr(b,o)
 char=None
 if f&2:char=struct.unpack_from('<H',b,o)[0];o+=2
 if f&4:o=matrix(b,o)
 if f&8:o=cxform(b,o,True)
 if f&16:o+=2
 name=None
 if f&32:name,o=cstr(b,o)
 return dict(depth=depth,char=char,name=name,flags=f)

def sha(b):return hashlib.sha256(b).hexdigest()

def tag(code,payload=b''):
 n=len(payload)
 return struct.pack('<H',(code<<6)|(n if n<63 else 63))+(struct.pack('<I',n) if n>=63 else b'')+payload

def parse(b,start,end):
 out=[];o=start
 while o<end:
  h=struct.unpack_from('<H',b,o)[0];code=h>>6;n=h&63;hd=2
  if n==63:n=struct.unpack_from('<I',b,o+2)[0];hd=6
  s=o+hd;e=s+n
  if e>end:raise ValueError(f'tag exceeds container at {o:#x}')
  out.append((code,b[s:e],o,b[o:e]));o=e
  if not code:
   if o!=end:raise ValueError(f'bytes after End: {end-o}')
   break
 if o!=end:raise ValueError('timeline lacks complete End')
 return out

def export_entries(payload):
 n=struct.unpack_from('<H',payload)[0];o=2;out=[]
 for _ in range(n):
  char=struct.unpack_from('<H',payload,o)[0];name,o=cstr(payload,o+2);out.append((char,name))
 if o!=len(payload):raise ValueError('extra export bytes')
 return out

def is_export(name):
 n=name.lower()
 return not n.endswith(('.tga','.png','.jpg')) and ('astore' in n or 'moregames' in n or n=='btn_buy_stars')

# iPod music player entry points (pause menu, sound options).
MUSIC_INSTANCES={'btn_music','playlist_btn'}

def is_instance(name):
 n=(name or '').lower()
 return any(v in n for v in ('astore','moregames')) or n in {
  'addcash_btn','addstar_btn','addcash_btnbg','addstar_btnbg','btn_tunning_addcash','show_rate_mc'} or n in MUSIC_INSTANCES

def empty_place(depth,char,name):
 # Only identity matrix + original instance name. No clip actions or hit shape.
 return tag(26,struct.pack('<BHH',0x26,depth,char)+b'\x00'+name.encode('utf-8')+b'\x00')

def inventory_defs(tags):
 defs={}
 for code,payload,offset,raw in tags:
  if code in DEFINES:
   char=struct.unpack_from('<H',payload)[0]
   if char in defs:raise ValueError(f'duplicate character {char}')
   defs[char]=(code,payload,offset,raw)
 return defs

def patch_file(b):
 start=12+(5+4*(b[8]>>3)+7)//8;top=parse(b,start,len(b));defs=inventory_defs(top)
 exports=[v for c,p,_,_ in top if c==56 for v in export_entries(p)]
 store_only=any(n=='AStoreHome' for _,n in exports) and any(n=='AStoreList' for _,n in exports)
 target_exports={c for c,n in exports if is_export(n)}
 new_defs=[];clone_ids={};changes=[];next_id=max(defs,default=0)+1
 def clone(original):
  nonlocal next_id
  if original in clone_ids:return clone_ids[original]
  if original not in defs:raise ValueError(f'undefined source character {original}')
  new_id=next_id;next_id+=1
  if new_id>65535:raise ValueError('character ID capacity')
  clone_ids[original]=new_id;code,payload,_,_=defs[original];children=[];seen=set();depth_chars={}
  if code==39:
   for c,p,o,raw in parse(payload,4,len(payload)):
    if c in (26,70):
     v=place(c,p);depth=v['depth']
     if v['char'] is not None:depth_chars[depth]=v['char']
     name=v['name'];child=depth_chars.get(depth)
     if name and name not in seen and child is not None:
      seen.add(name);children.append(empty_place(len(children)+1,clone(child),name))
    elif c==5:depth_chars.pop(struct.unpack_from('<H',p,2)[0],None)
    elif c==28:depth_chars.pop(struct.unpack_from('<H',p)[0],None)
  # Child identities remain present, but every clone is an empty movie clip.
  sprite=struct.pack('<HH',new_id,1)+b''.join(children)+tag(1)+tag(0)
  new_defs.append(tag(39,sprite));return new_id
 def timeline(rows,path,blank=False):
  out=[];active={};depth_chars={}
  for code,payload,offset,raw in rows:
   if code==59 and struct.unpack_from('<H',payload)[0] in target_exports:
    changes.append(dict(kind='remove_store_export_registration',timeline=path,offset=offset,character=struct.unpack_from('<H',payload)[0]));continue
   if code==39:
    cid,frames=struct.unpack_from('<HH',payload);rewritten=timeline(parse(payload,4,len(payload)),f'sprite:{cid}')
    out.append(tag(39,payload[:4]+rewritten));continue
   if code==56:
    entries=export_entries(payload);result=[]
    for cid,name in entries:
     replacement=clone(cid) if is_export(name) else cid
     result.append(struct.pack('<H',replacement)+name.encode('utf-8')+b'\x00')
     if replacement!=cid:changes.append(dict(kind='empty_export',timeline=path,offset=offset,name=name,original_character=cid,empty_character=replacement))
    out.append(tag(code,struct.pack('<H',len(entries))+b''.join(result)));continue
   if code in (26,70):
    v=place(code,payload);depth=v['depth'];cid=v['char'];name=v['name']
    if cid is not None:depth_chars[depth]=cid
    prior=active.get(depth)
    if name is not None and not is_instance(name) and cid not in target_exports:prior=None;active.pop(depth,None)
    if cid is not None and not name and cid not in target_exports and prior and cid!=prior[0]:prior=None;active.pop(depth,None)
    selected=blank or is_instance(name) or cid in target_exports or bool(prior and cid is None)
    if selected:
     original=cid if cid is not None else depth_chars.get(depth)
     if original is None:raise ValueError('selected instance without character')
     instance_name=name or (prior[1] if prior else f'__removed_purchase_{depth}')
     replacement=clone(original);active[depth]=(original,instance_name)
     out.append(empty_place(depth,replacement,instance_name));changes.append(dict(kind='empty_instance',timeline=path,offset=offset,name=instance_name,depth=depth,original_character=original,empty_character=replacement))
    else:out.append(raw)
    continue
   if blank and code in (4,12,59):
    # Store-only movie root has no timeline actions or legacy placements.
    changes.append(dict(kind='remove_store_root_action',timeline=path,offset=offset,tag=code));continue
   if code==5:active.pop(struct.unpack_from('<H',payload,2)[0],None)
   if code==28:active.pop(struct.unpack_from('<H',payload)[0],None)
   out.append(raw)
  return b''.join(out)
 body=timeline(top,'root',store_only)
 if not changes:return None
 # New definitions precede all placements; original character definitions remain
 # for non-store consumers that share them. Alias exports select the empty clone.
 prefix_length=len(top[0][3]) if top and top[0][0]==69 else 0
 patched=b[:start]+body[:prefix_length]+b''.join(new_defs)+body[prefix_length:]
 patched=patched[:4]+struct.pack('<I',len(patched))+patched[8:]
 return patched,dict(store_only=store_only,original_sha256=sha(b),patched_sha256=sha(patched),original_size=len(b),patched_size=len(patched),changes=changes,empty_character_ids=sorted(clone_ids.values()),original_character_ids=sorted(defs))

def validate(patched,details):
 start=12+(5+4*(patched[8]>>3)+7)//8;top=parse(patched,start,len(patched));defs=inventory_defs(top);ids=set(defs);empty=set(details['empty_character_ids']);references=[];names=[]
 def inspect(rows,path,empty_timeline=False):
  for code,p,o,raw in rows:
   if code==39:
    char=struct.unpack_from('<H',p)[0];inspect(parse(p,4,len(p)),f'sprite:{char}',char in empty)
   elif code in (26,70):
    v=place(code,p)
    if v['char'] is not None:
     references.append(v['char'])
     if empty_timeline and v['char'] not in empty:raise ValueError('empty skeleton points to visible original')
     if is_instance(v['name']) and v['char'] not in empty:raise ValueError('entry points to original character')
    if empty_timeline and (code!=26 or p[0]!=0x26):raise ValueError('skeleton placement has events/effects')
   elif code==56:
    for cid,name in export_entries(p):
     references.append(cid)
     if is_export(name) and cid not in empty:raise ValueError('store export points to original character')
   elif empty_timeline and code not in (0,1):raise ValueError('drawing/action/hit tag in empty skeleton')
 inspect(top,'root')
 if set(references)-ids:raise ValueError(f'dangling character IDs {set(references)-ids}')
 if not set(details['original_character_ids'])<=ids:raise ValueError('original definition removed')
 return dict(valid_tag_lengths=True,declared_length_matches=struct.unpack_from('<I',patched,4)[0]==len(patched),all_character_references_defined=True,original_definitions_retained=True,store_aliases_point_to_inert_skeletons=True,store_export_class_registrations_removed=True,skeletons_have_no_drawing_actions_or_hit_shapes=True,original_actionscript_identifiers_retained=True,runtime_menu_and_race_verified=False)

