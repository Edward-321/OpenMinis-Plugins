#!/usr/bin/env python3
"""Validate real build products and package an explicitly unsigned IPA."""
import pathlib,os,plistlib,subprocess,shutil,json,hashlib,zipfile,re,tempfile
root=pathlib.Path.cwd(); config=os.environ.get('CONFIGURATION','Release')
app=root/f'build/DerivedData/Build/Products/{config}-iphoneos/Minis.app'
dist=root/'dist';dist.mkdir(exist_ok=True)
assert app.is_dir(),'Actual Minis.app not produced'
for ext in ('MinisShare','MinisFileProvider','AgentWidgetExtension'):
    assert (app/'PlugIns'/f'{ext}.appex').is_dir(),'Missing original extension '+ext
assert (app/'alpine-rootfs.zip').stat().st_size>1000000,'Missing actual Alpine image'
assert (app/'RootfsPatch.bundle').is_dir(),'Missing runtime rootfs patch bundle'
def ver(s):return tuple((list(map(int,s.split('.')))+[0,0,0])[:3])
bundles=[app]+[p for p in app.rglob('*') if p.is_dir() and p.suffix in ('.framework','.appex')]
checked=[]
for b in bundles:
    info=plistlib.loads((b/'Info.plist').read_bytes())
    minimum=info.get('MinimumOSVersion')
    if minimum:assert ver(minimum)<=ver('17.1.2'),f'{b.name} requires iOS {minimum}, target is 17.1.2'
    name=info.get('CFBundleExecutable')
    assert name and (b/name).is_file(),'Missing bundle executable: '+str(b)
    binary=b/name
    arches=subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip()
    assert 'arm64' in arches,'Missing iPhone architecture: '+str(binary)
    loads=subprocess.check_output(['otool','-l',str(binary)],text=True)
    for value in re.findall(r'^\s*(?:minos|version)\s+(\d+\.\d+(?:\.\d+)?)\s*$',loads,re.M):
        # LC_VERSION_MIN_IPHONEOS and LC_BUILD_VERSION minos are handled below;
        # dylib current/compatibility versions are intentionally ignored.
        pass
    for block in loads.split('Load command ')[1:]:
        if 'cmd LC_BUILD_VERSION' in block:
            m=re.search(r'^\s*minos\s+([\d.]+)',block,re.M)
        elif 'cmd LC_VERSION_MIN_IPHONEOS' in block:
            m=re.search(r'^\s*version\s+([\d.]+)',block,re.M)
        else:continue
        if m:assert ver(m[1])<=ver('17.1.2'),f'{binary.name} Mach-O minimum is {m[1]}'
    checked.append({'bundle':str(b.relative_to(app.parent)),'minimum_ios':minimum,'architectures':arches})
ipa=dist/'Minis-unsigned.ipa'
with tempfile.TemporaryDirectory(prefix='minis-ipa-') as td:
    payload=pathlib.Path(td)/'Payload';payload.mkdir()
    shutil.copytree(app,payload/'Minis.app',symlinks=True)
    subprocess.run(['ditto','-c','-k','--norsrc','--keepParent','Payload',str(ipa)],cwd=td,check=True)
with zipfile.ZipFile(ipa) as z:
    assert z.testzip() is None,'IPA ZIP checksum failure'
    assert 'Payload/Minis.app/Info.plist' in z.namelist()
    assert 'Payload/Minis.app/alpine-rootfs.zip' in z.namelist()
sha=hashlib.sha256(ipa.read_bytes()).hexdigest()
(dist/'SHA256SUMS').write_text(sha+'  '+ipa.name+'\n')
report={'status':'built_unsigned_requires_user_signing','installation_tested':False,'signing_performed':False,'device_runtime_tested':False,'sha256':sha,'ipa_bytes':ipa.stat().st_size,'target_ios':'17.1.2','repository_commit':os.environ.get('GITHUB_SHA'),'upstream_commit':'f74bca69aaf028209a80435e8c805cb5db21bfa9','github_run_id':os.environ.get('GITHUB_RUN_ID'),'validated_bundles':checked}
(dist/'build-info.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False,indent=2))
