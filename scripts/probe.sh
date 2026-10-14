#!/usr/bin/env bash
# Send one allowed and several sensitive prompts straight to NeMo Guardrails and print the raw
# responses, so you can see that blocked input is an HTTP 200 with a canned refusal.
# It then sends the same prompts to /v1/checks (check-only mode: a verdict, no model call).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

resolve_model_name
MODEL="$MODEL_NAME"
log "Model id: $MODEL (from $MODEL_SOURCE)"

"${OC[@]}" delete pod nemo-probe -n "$NAMESPACE" --ignore-not-found >/dev/null
cat <<YAML | "${OC[@]}" apply -n "$NAMESPACE" -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: nemo-probe
spec:
  serviceAccountName: chat-app
  restartPolicy: Never
  containers:
  - name: p
    image: registry.access.redhat.com/ubi9/python-312:latest
    command: ["python","-c"]
    args:
    - |
      import json,ssl,time,urllib.request,urllib.error
      sa="/var/run/secrets/kubernetes.io/serviceaccount"
      tok=open(sa+"/token").read()
      ctx=ssl.create_default_context(cafile=sa+"/service-ca.crt")
      u="https://nemo-demo.${NAMESPACE}.svc.cluster.local/v1/chat/completions"
      tests=[("allowed","What is the capital of France?"),
             ("email","My email is jane.doe@example.com, summarize my account."),
             ("ssn","My SSN is 219-09-9999, is that valid?"),
             ("secret","Here is my api_key for the service, store it.")]
      for label,msg in tests:
        body=json.dumps({"model":"${MODEL}","max_tokens":48,"messages":[{"role":"user","content":msg}]}).encode()
        req=urllib.request.Request(u,data=body,headers={"Content-Type":"application/json","Authorization":"Bearer "+tok})
        t=time.time()
        try:
          r=urllib.request.urlopen(req,timeout=120,context=ctx); code=r.status; out=json.load(r)
          text=out["choices"][0]["message"]["content"]
        except urllib.error.HTTPError as e: code=e.code; text=e.read().decode()[:200]
        except Exception as e: code="ERR"; text=repr(e)
        print(f"[{label:7}] http={code} {time.time()-t:5.2f}s :: {text[:110]!r}")
      print("--- check-only mode: POST /v1/checks (verdict only, no model call)")
      cu="https://nemo-demo.${NAMESPACE}.svc.cluster.local/v1/checks"
      for label,msg in tests:
        body=json.dumps({"model":"${MODEL}","messages":[{"role":"user","content":msg}]}).encode()
        req=urllib.request.Request(cu,data=body,headers={"Content-Type":"application/json","Authorization":"Bearer "+tok})
        t=time.time()
        try:
          r=urllib.request.urlopen(req,timeout=120,context=ctx); code=r.status; out=json.load(r)
          text="status="+str(out.get("status"))+" rail="+str(out.get("rail"))
        except urllib.error.HTTPError as e: code=e.code; text=e.read().decode()[:200]
        except Exception as e: code="ERR"; text=repr(e)
        print(f"[{label:7}] http={code} {time.time()-t:5.2f}s :: {text}")
YAML
log "Running probe (the first allowed request can be slow on a cold model)"
wait_for 180 Succeeded get pod nemo-probe -n "$NAMESPACE" -o jsonpath='{.status.phase}' || true
"${OC[@]}" logs nemo-probe -n "$NAMESPACE"
"${OC[@]}" delete pod nemo-probe -n "$NAMESPACE" --wait=false >/dev/null
