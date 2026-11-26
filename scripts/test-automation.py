#!/usr/bin/env python3
"""Exercise the actual app through STDIO MCP in an explicitly selected test directory."""
import argparse
import json
import selectors
import socket
import subprocess
import uuid
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--data-dir', required=True)
parser.add_argument('--cli', required=True)
parser.add_argument('--result', required=True)
args = parser.parse_args()
cli, directory = str(Path(args.cli).resolve()), Path(args.data_dir).resolve()
checks = []

class MCP:
    def __init__(self, readonly=False):
        self.p = subprocess.Popen([cli, '--data-dir', str(directory), *(['--read-only'] if readonly else []), 'mcp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.n = 0
        info = self.rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'branchline-integration-test', 'version': '1'}})
        assert info['result']['serverInfo']['name'] == 'branchline'
        self.p.stdin.write(json.dumps({'jsonrpc':'2.0','method':'notifications/initialized'})+'\n'); self.p.stdin.flush()
    def rpc(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({'jsonrpc':'2.0','id':self.n,'method':method,'params':params or {}}, ensure_ascii=False)+'\n'); self.p.stdin.flush()
        selector = selectors.DefaultSelector(); selector.register(self.p.stdout, selectors.EVENT_READ)
        try:
            assert selector.select(12), 'MCP response timeout (stdout must be flushed)'
            line = self.p.stdout.readline()
            assert line, 'MCP process exited'
            result = json.loads(line); assert result['id'] == self.n
            return result
        finally: selector.close()
    def tool(self, name, arguments=None):
        result = self.rpc('tools/call', {'name':name, 'arguments':arguments or {}})
        assert 'result' in result, result
        return json.loads(result['result']['content'][0]['text'])
    def close(self):
        self.p.stdin.close(); self.p.wait(timeout=5)

mcp = MCP()
try:
    catalog = mcp.rpc('tools/list')['result']['tools']
    assert len(catalog) == 9
    assert mcp.rpc('ping')['result'] == {}
    checks.append('MCP initialize/notifications/ping/catalog (9 tools)')
    caps = mcp.tool('get_capabilities')['result']
    original_count = mcp.tool('list_projects')['result']['total']
    rid = 'integration-' + str(uuid.uuid4())
    def create(entity, ref, fields): return {'action':'create','entity':entity,'ref':ref,'fields':fields}
    request = {'requestID':rid, 'expectedRevision':caps['revision'], 'operations':[
        create('project','p',{'title':'MCP 验收项目','note':'独立测试资料库'}),
        create('branch','b',{'title':'接口验证','projectIDs':['$p'],'originProjectID':'$p'}),
        create('record','t1',{'kind':'task','title':'验证读取','branchID':'$b'}),
        create('record','t2',{'kind':'task','title':'验证写入','branchID':'$b','dependencies':['$t1']}),
        create('record','r',{'kind':'progress','title':'MCP 已创建进度','body':'通过真实 STDIO MCP 写入','branchID':'$b'}),
        create('record','meeting',{'kind':'meeting','title':'接口评审','branchID':'$b','startAt':'2026-11-05T10:00:00+08:00','endAt':'2026-11-05T11:00:00+08:00'})
    ]}
    preview = mcp.tool('preview_changes',request)
    assert preview['ok'] and not preview['result']['applied'], preview
    assert mcp.tool('list_projects')['result']['total'] == original_count
    checks.append('Preview validates without writing')
    applied = mcp.tool('apply_changes',request)
    assert applied['ok'] and applied['result']['applied'], applied
    ids = applied['result']['receipt']['ids']
    assert mcp.tool('list_projects')['result']['total'] == original_count+1
    context = mcp.tool('get_project_context', {'projectID':ids['p']})['result']
    assert len(context['branches']) == 1 and len(context['items']) == 4
    checks.append('Atomic project/branch/progress/tasks/dependency/meeting creation')
    assert mcp.tool('apply_changes',request)['result']['replayed']
    checks.append('Identical retries do not create duplicate entities')
    def batch(ops, revision=None): return {'requestID':str(uuid.uuid4()),'expectedRevision':revision or mcp.tool('get_capabilities')['result']['revision'],'operations':ops}
    def update(entity, id, fields): return {'action':'update','entity':entity,'id':id,'fields':fields}
    blocked = mcp.tool('apply_changes',batch([update('record',ids['t2'],{'status':'completed'})]))
    assert not blocked['ok']
    checks.append('Unfinished dependency rejects completion')
    revision = mcp.tool('get_capabilities')['result']['revision']
    valid = batch([update('record',ids['r'],{'title':'MCP 修改成功','body':'修改已保存，其他字段保留'})],revision)
    concurrent = batch([update('record',ids['t1'],{'title':'旧版本不应覆盖'})],revision)
    assert mcp.tool('apply_changes',valid)['ok']
    other = MCP()
    try:
        conflict = other.tool('apply_changes',concurrent)
        assert not conflict['ok'] and 'revision_conflict' in conflict['error']
    finally: other.close()
    checks.append('Two MCP clients share one writer; stale concurrent update rejected')
    readback = mcp.tool('get_record',{'id':ids['r']})['result']['record']
    assert readback['title'] == 'MCP 修改成功' and readback['branchID'] == ids['b']
    checks.append('Readback preserves unrelated relationship fields')
    failed = batch([create('project','bad-p',{'title':'不应部分保存'}),create('record','bad-r',{'kind':'progress','title':'无效','branchID':str(uuid.uuid4())})])
    assert not mcp.tool('apply_changes',failed)['ok']
    assert mcp.tool('list_projects')['result']['total'] == original_count+1
    checks.append('Invalid batch has no partial writes')
    done = batch([update('record',ids['t1'],{'status':'completed'}),update('record',ids['t2'],{'status':'completed'})])
    assert mcp.tool('apply_changes',done)['ok']
    merge = batch([create('merge','m',{'branchID':ids['b'],'projectID':ids['p'],'summary':'完成本地读取与写入验证','sourceRecordIDs':[ids['r']]})])
    assert mcp.tool('apply_changes',merge)['ok']
    checks.append('Dependency-ordered completion and outcome merge')
    changes = mcp.tool('get_changes')['result']['items']
    assert any(r['requestID'] == rid for r in changes)
    assert mcp.tool('get_operation_result',{'requestID':rid})['result']['receipt']['ids'] == ids
    checks.append('Durable operation receipts and before/after history')
    readonly = MCP(True)
    try:
        assert 'apply_changes' not in [t['name'] for t in readonly.rpc('tools/list')['result']['tools']]
        assert readonly.tool('list_projects')['ok']
        assert 'error' in readonly.rpc('tools/call',{'name':'apply_changes','arguments':request})
    finally: readonly.close()
    checks.append('Read-only MCP bridge lists no write tool and rejects direct invocation')
    endpoint = json.loads((directory/'automation-endpoint.json').read_text())
    assert (directory/'automation-endpoint.json').stat().st_mode & 0o777 == 0o600
    with socket.create_connection(('127.0.0.1',endpoint['port']),timeout=5) as s:
        s.sendall((json.dumps({'token':'wrong','method':'list_projects','arguments':{}})+'\n').encode())
        denied = json.loads(s.makefile().readline()); assert not denied['ok'] and denied['error'] == 'unauthorized'
    checks.append('Wrong token rejected; endpoint mode is 0600')
    assert list((directory/'Backups').glob('before-automation-*.json'))
    checks.append('Automatic backup exists before external writes')
    Path(args.result).write_text(json.dumps({'checks':checks,'request':request,'ids':ids},ensure_ascii=False,indent=2))
    print('\n'.join('PASS: '+v for v in checks))
    print(f'{len(checks)}/{len(checks)} integration checks passed')
finally:
    mcp.close()
