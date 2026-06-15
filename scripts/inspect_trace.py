import json, pathlib
p=pathlib.Path(r'E:/workspace/ai-gateway/moqui_logs/assistant-chat-trace.jsonl')
for i,l in enumerate(p.read_text(encoding='utf-8').splitlines(),1):
 o=json.loads(l)
 s=json.dumps(o,ensure_ascii=False)
 if o.get('requestId') in ['REQ-MQ5C1RM8-HMLC','REQ-MQ57DTQP-CHXG'] or 'run_command approval required' in s:
 print('---',i)
 print(s[:4000])
