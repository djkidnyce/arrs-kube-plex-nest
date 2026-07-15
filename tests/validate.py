#!/usr/bin/env python3
"""
Offline validation of rendered chart manifests.
Usage: python3 tests/validate.py <rendered.yaml>
Checks:
  1. Kubernetes schema validity (kubernetes-validate)
  2. Cross-references: PVCs, Secrets, ConfigMaps referenced by pods exist
     (Secrets may be in the documented imperative list)
  3. Service selectors match pod labels; service targetPorts exist as containerPorts
  4. Security invariants: no :latest, no HPA, automountServiceAccountToken false,
     seccompProfile on every pod, resources on every container, probes on
     long-running containers, single replica on SQLite apps, plex replicas >= 2
"""
import sys, yaml

IMPERATIVE_SECRETS = {
    "smb-credentials", "plex-claim", "vpn-credentials",
    "clamav-notify", "gluetun-control-auth", "vpn-ovpn-configs",
}
SQLITE_APPS = {"sabnzbd", "sonarr", "radarr", "lidarr", "seerr", "tautulli"}

fails = []
def check(ok, msg):
    print(("PASS  " if ok else "FAIL  ") + msg)
    if not ok:
        fails.append(msg)

def pod_spec(doc):
    k = doc["kind"]
    if k in ("Deployment", "StatefulSet"):
        return doc["spec"]["template"]["spec"]
    if k == "CronJob":
        return doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return None

def containers(spec):
    return spec.get("initContainers", []) + spec.get("containers", [])

def main(path):
    docs = [d for d in yaml.safe_load_all(open(path)) if d]
    check(len(docs) > 0, f"rendered {len(docs)} manifests")

    # 1. schema validation
    try:
        import kubernetes_validate
        errs = 0
        for d in docs:
            try:
                kubernetes_validate.validate(d, "1.29", strict=True)
            except Exception as e:
                errs += 1
                print(f"      schema error in {d['kind']}/{d['metadata']['name']}: {e}")
        check(errs == 0, f"kubernetes schema validation (k8s 1.29, strict): {errs} errors")
    except ImportError:
        print("SKIP  kubernetes-validate not installed")

    pvcs = {d["metadata"]["name"] for d in docs if d["kind"] == "PersistentVolumeClaim"}
    cms = {d["metadata"]["name"] for d in docs if d["kind"] == "ConfigMap"}
    secrets = {d["metadata"]["name"] for d in docs if d["kind"] == "Secret"}
    check(len(secrets) == 0, "no Secret objects in the chart (imperative-only)")

    workloads = [d for d in docs if pod_spec(d)]
    for d in workloads:
        name = f'{d["kind"]}/{d["metadata"]["name"]}'
        spec = pod_spec(d)
        # 2. references
        for v in spec.get("volumes", []):
            if "persistentVolumeClaim" in v:
                claim = v["persistentVolumeClaim"]["claimName"]
                check(claim in pvcs, f"{name}: PVC '{claim}' exists")
            if "configMap" in v:
                check(v["configMap"]["name"] in cms, f"{name}: ConfigMap '{v['configMap']['name']}' exists")
            if "secret" in v:
                sn = v["secret"]["secretName"]
                check(sn in IMPERATIVE_SECRETS, f"{name}: Secret '{sn}' documented imperative")
        for c in containers(spec):
            for e in c.get("env", []):
                vf = e.get("valueFrom", {})
                if "secretKeyRef" in vf:
                    check(vf["secretKeyRef"]["name"] in IMPERATIVE_SECRETS,
                          f"{name}/{c['name']}: env secret '{vf['secretKeyRef']['name']}' documented")
                if "configMapKeyRef" in vf:
                    check(vf["configMapKeyRef"]["name"] in cms,
                          f"{name}/{c['name']}: env configmap '{vf['configMapKeyRef']['name']}' exists")
            # 4. hardening invariants
            check(":latest" not in c["image"], f"{name}/{c['name']}: image pinned ({c['image']})")
            check(bool(c.get("resources", {}).get("limits")), f"{name}/{c['name']}: resource limits set")
            sec = c.get("securityContext", {})
            check(sec.get("allowPrivilegeEscalation") is False, f"{name}/{c['name']}: allowPrivilegeEscalation false")
            check("ALL" in (sec.get("capabilities", {}).get("drop") or []), f"{name}/{c['name']}: caps drop ALL")
        check(spec.get("automountServiceAccountToken") is False, f"{name}: SA token not mounted")
        check(spec.get("securityContext", {}).get("seccompProfile", {}).get("type") == "RuntimeDefault",
              f"{name}: seccomp RuntimeDefault")
        # long-running containers have probes
        if d["kind"] in ("Deployment", "StatefulSet"):
            for c in spec["containers"]:
                if c["name"] in ("gluetun", "vpn-rotator"):
                    continue
                check("livenessProbe" in c and "readinessProbe" in c, f"{name}/{c['name']}: probes present")
        # replica rules
        app = d["metadata"].get("labels", {}).get("app")
        if d["kind"] == "Deployment" and app in SQLITE_APPS:
            check(d["spec"]["replicas"] == 1, f"{name}: single replica (SQLite)")
            check(d["spec"].get("strategy", {}).get("type") == "Recreate", f"{name}: Recreate strategy")
        if d["kind"] == "StatefulSet" and app == "plex":
            check(d["spec"]["replicas"] >= 2, f"{name}: >= 2 plex servers ({d['spec']['replicas']})")

    check(not any(d["kind"] == "HorizontalPodAutoscaler" for d in docs), "no HPA (Plex cannot autoscale)")

    # 3. service selectors and ports
    pods_by_labels = []
    for d in workloads:
        tmpl = d["spec"]["template"] if d["kind"] in ("Deployment", "StatefulSet") else None
        if tmpl:
            ports = set()
            for c in tmpl["spec"]["containers"]:
                for p in c.get("ports", []):
                    ports.add(p["containerPort"])
            pods_by_labels.append((tmpl["metadata"]["labels"], ports, d["metadata"]["name"]))
    for d in [x for x in docs if x["kind"] == "Service"]:
        sel = d["spec"].get("selector") or {}
        core = {k: v for k, v in sel.items() if not k.startswith("statefulset.kubernetes.io")}
        matches = [(l, ports, n) for l, ports, n in pods_by_labels if all(l.get(k) == v for k, v in core.items())]
        check(bool(matches), f"Service/{d['metadata']['name']}: selector matches a workload")
        for p in d["spec"]["ports"]:
            tp = p.get("targetPort", p["port"])
            ok = any(tp in ports or not ports for _, ports, _ in matches)
            check(ok, f"Service/{d['metadata']['name']}: targetPort {tp} exposed by pod")

    print()
    if fails:
        print(f"{len(fails)} FAILURES"); sys.exit(1)
    print("ALL CHECKS PASSED"); sys.exit(0)

if __name__ == "__main__":
    main(sys.argv[1])
