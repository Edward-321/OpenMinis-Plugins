#!/usr/bin/env python3
"""Restore missing files from a matching, pinned public upstream checkout.
Existing source/custom plugin changes are NEVER overwritten.
"""
import pathlib,subprocess,json,hashlib,sys,os
PIN='f74bca69aaf028209a80435e8c805cb5db21bfa9'
ISH_PIN='0fd17a135e78b7a0cf08a4f5831217bbb76ed22f'
root=pathlib.Path.cwd();up=(root/sys.argv[1]).resolve()
assert up.is_relative_to(root) and up!=root
sha=subprocess.check_output(['git','-C',str(up),'rev-parse','HEAD'],text=True).strip()
assert sha==PIN, 'Unexpected upstream commit'
ish=subprocess.check_output(['git','-C',str(up/'deps/ish'),'rev-parse','HEAD'],text=True).strip()
assert ish==ISH_PIN, 'Unexpected iSH submodule commit'
paths=['src/ios','src/shared','scripts','deps/ish']
protected=['src/ios/Agent/Session/PluginStore.swift','src/ios/Views/Settings/PluginsSettingsView.swift','src/ios/Agent/Chat/AIChatViewModel+AgentLoop.swift','src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift','src/ios/Views/Settings/SettingsSheet.swift','src/ios/Views/Chat/Markdown/Rendering/MarkdownNSRenderer.swift','src/ios/Minis.xcodeproj/project.pbxproj','deps/ish/vdso/arm64/meson.build']
def digest(p):return hashlib.sha256((root/p).read_bytes()).hexdigest()
before={p:digest(p) for p in protected if (root/p).is_file()}
summary=[]
for rel in paths:
    src=up/rel;dst=root/rel
    assert src.is_dir(), 'Missing upstream directory: '+rel
    dst.mkdir(parents=True,exist_ok=True)
    result=subprocess.run(['rsync','-a','--ignore-existing','--exclude=.git','--itemize-changes',str(src)+'/',str(dst)+'/'],check=True,text=True,stdout=subprocess.PIPE)
    summary.append({'path':rel,'restored_entries':len(result.stdout.splitlines())})
for p,h in before.items():assert digest(p)==h,'Custom source overwritten: '+p
required=['src/ios/MinisApp.swift','src/ios/MinisApp-Bridging-Header.h','scripts/gen_debug_skill.sh']
for p in required:assert (root/p).is_file(),'Source remains missing: '+p
for p in ['src/ios/ShareExtension','src/ios/FileProvider','src/ios/AgentWidget']:
    assert (root/p).is_dir(),'Extension remains missing: '+p
out=root/'build/diagnostics';out.mkdir(parents=True,exist_ok=True)
(out/'source-recovery.json').write_text(json.dumps({'upstream':PIN,'ish':ISH_PIN,'restored':summary,'preserved_custom_sha256':before},indent=2))
print(json.dumps({'upstream':PIN,'restored':summary,'preserved_custom_files':len(before)},indent=2))
