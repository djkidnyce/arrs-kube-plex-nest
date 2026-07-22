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
                if "secretKeyRef" in vf and not vf["secretKeyRef"].get("optional"):
                    check(vf["secretKeyRef"]["name"] in IMPERATIVE_SECRETS,
                          f"{name}/{c['name']}: env secret '{vf['secretKeyRef']['name']}' documented")
                if "configMapKeyRef" in vf and not vf["configMapKeyRef"].get("optional"):
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

    # ── gluetun runtime requirements (all six verified on a live cluster) ──
    for d in workloads:
        if d["metadata"]["name"] != "sabnzbd":
            continue
        spec = pod_spec(d)
        g = [c for c in spec["containers"] if c["name"] == "gluetun"][0]
        env = {e["name"]: e for e in g.get("env", [])}
        caps = set(g["securityContext"]["capabilities"].get("add") or [])

        # capabilities: dropping ALL removes root's implicit powers, so each of
        # these is load-bearing (tunnel, config write, privilege drop)
        for cap in ("NET_ADMIN", "CHOWN", "DAC_OVERRIDE", "SETUID", "SETGID"):
            check(cap in caps, f"gluetun capability {cap} present")

        # OPENVPN_CUSTOM_CONFIG must name a FILE, never a directory
        occ = env.get("OPENVPN_CUSTOM_CONFIG", {}).get("value")
        if occ is not None:
            check(occ.endswith(".ovpn"), f"OPENVPN_CUSTOM_CONFIG is a file, not a dir ({occ})")

        # native mode wiring
        provider = env.get("VPN_SERVICE_PROVIDER", {}).get("value")
        if provider and provider != "custom":
            check("OPENVPN_USER" in env and "OPENVPN_PASSWORD" in env,
                  f"native mode ({provider}): OPENVPN_USER/PASSWORD wired")
            check(occ is None, "native mode: no OPENVPN_CUSTOM_CONFIG")
            init_names = [c["name"] for c in spec.get("initContainers", [])]
            check("patch-ovpn-creds" not in init_names, "native mode: no .ovpn patch init container")
            for vol in spec.get("volumes", []):
                check(vol["name"] != "vpn-cred-file",
                      "native mode: openvpn.cred not mounted (missing key hangs the pod)")

        # SABnzbd probes must not be HTTP: /api returns 403 without an API key
        sab = [c for c in spec["containers"] if c["name"] == "sabnzbd"][0]
        for probe in ("livenessProbe", "readinessProbe", "startupProbe"):
            if probe in sab:
                check("httpGet" not in sab[probe],
                      f"sabnzbd {probe} is not HTTP (/api needs an API key)")

    # ── v1.1.5 guards ────────────────────────────────────────────────────
    svcs = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Service"}
    cms = {d["metadata"]["name"] for d in docs if d["kind"] == "ConfigMap"}

    # Seerr (native image) mounts at /app/config; the deprecated LSIO overseerr
    # used /config. Detailed seerr checks are below.

    # SABnzbd settings are seeded by an init container, never edited live
    for d in workloads:
        if d["metadata"]["name"] != "sabnzbd":
            continue
        inits = [c["name"] for c in pod_spec(d).get("initContainers", [])]
        # Seeding is optional, but the ConfigMap and the init container must
        # always agree: one without the other is a broken render.
        seed_cm = "sabnzbd-seed" in cms
        seed_init = "seed-sabnzbd-config" in inits
        check(seed_cm == seed_init,
              f"sabnzbd: seed ConfigMap ({seed_cm}) and init container ({seed_init}) agree")
        if seed_init:
            sc = [c for c in pod_spec(d)["initContainers"] if c["name"] == "seed-sabnzbd-config"][0]
            mounts = [m["mountPath"] for m in sc["volumeMounts"]]
            check("/config" in mounts, "sabnzbd seed: writes to the config PVC")

    # exposed services publish a port AND have a matching ingress policy
    nps = [d for d in docs if d["kind"] == "NetworkPolicy"]
    allowed_ports = set()
    for p in nps:
        for rule in p["spec"].get("ingress") or []:
            if "from" not in rule:
                for prt in rule.get("ports", []):
                    allowed_ports.add(prt["port"])
    for name, svc in svcs.items():
        stype = svc["spec"].get("type", "ClusterIP")
        if stype in ("NodePort", "LoadBalancer"):
            for prt in svc["spec"]["ports"]:
                tp = prt.get("targetPort", prt["port"])
                check(tp in allowed_ports,
                      f"{name}: exposed as {stype}, ingress allowed on {tp}")
            if stype == "NodePort":
                for prt in svc["spec"]["ports"]:
                    np = prt.get("nodePort")
                    check(np is not None and 30000 <= np <= 32767,
                          f"{name}: nodePort {np} pinned and in range")

    # backup job: read-only config mounts, writable share, sane security
    for d in docs:
        if d["kind"] != "CronJob" or d["metadata"]["name"] != "config-backup":
            continue
        spec = pod_spec(d)
        c = spec["containers"][0]
        vols = {v["name"]: v for v in spec["volumes"]}
        mounts = {m["name"]: m for m in c["volumeMounts"]}
        check(mounts.get("media", {}).get("readOnly") is not True,
              "backup: media share mounted writable (destination)")
        cfgvols = [n for n in vols if n.endswith("-config")]
        check(bool(cfgvols), "backup: at least one config volume mounted")
        for n in cfgvols:
            check(vols[n]["persistentVolumeClaim"].get("readOnly") is True,
                  f"backup: {n} claim is readOnly")
            check(mounts[n].get("readOnly") is True, f"backup: {n} mount is readOnly")
        check(c["securityContext"].get("readOnlyRootFilesystem") is True,
              "backup: read-only root filesystem")
        check(spec["securityContext"].get("runAsNonRoot") is True,
              "backup: runs non-root")
        apps_env = [e["value"] for e in c["env"] if e["name"] == "APPS"][0].split()
        for app in apps_env:
            check(f"{app}-config" in vols, f"backup: {app} listed in APPS has its PVC mounted")

    # Seerr: native image, /app/config path, rootless securityContext
    for d in workloads:
        if d["metadata"]["name"] != "seerr":
            continue
        spec = pod_spec(d)
        c = spec["containers"][0]
        check("seerr-team/seerr" in c["image"], "seerr: native seerr image (not deprecated overseerr)")
        mounts = [m["mountPath"] for m in c["volumeMounts"]]
        check("/app/config" in mounts, "seerr: config at /app/config")
        check(spec["securityContext"].get("runAsNonRoot") is True, "seerr: rootless")
        check(spec["securityContext"].get("runAsUser") == 1000, "seerr: runs as 1000 (node user)")

    # SABnzbd downloads scratch off the media share
    dl = [d for d in docs if d["kind"] == "PersistentVolumeClaim" and d["metadata"]["name"] == "sabnzbd-downloads"]
    if dl:
        for d in workloads:
            if d["metadata"]["name"] != "sabnzbd":
                continue
            sab = [c for c in pod_spec(d)["containers"] if c["name"] == "sabnzbd"][0]
            mp = [m["mountPath"] for m in sab["volumeMounts"]]
            check("/downloads" in mp, "sabnzbd: local downloads volume mounted")
        cm = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "sabnzbd-seed"]
        if cm:
            dd = cm[0]["data"].get("DOWNLOAD_DIR", "")
            cd = cm[0]["data"].get("COMPLETE_DIR", "")
            check(dd.startswith("/downloads"), "sabnzbd seed: incomplete dir on local PVC (downloads enabled)")
            check(cd.startswith("/mnt/media"), "sabnzbd seed: complete dir on the share (same-fs imports)")

    # Prowlarr, when enabled, has deployment + service + pvc and can reach the arrs
    pw_dep = [d for d in workloads if d["metadata"]["name"] == "prowlarr"]
    if pw_dep:
        check(any(d["kind"] == "PersistentVolumeClaim" and d["metadata"]["name"] == "prowlarr-config" for d in docs),
              "prowlarr: config PVC present")
        check(any(d["kind"] == "Service" and d["metadata"]["name"] == "prowlarr" for d in docs),
              "prowlarr: service present")
        af = [d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"] == "arrs-from-seerr"]
        if af:
            vals = af[0]["spec"]["ingress"][0]["from"][0]["podSelector"]["matchExpressions"][0]["values"]
            check("prowlarr" in vals, "prowlarr: allowed to reach the *arrs for indexer sync")

    # ClamAV scans must exclude backups, reports, and the incomplete download dir
    clcm = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "clamav-config"]
    if clcm:
        excl = clcm[0]["data"].get("EXCLUDE_DIRS", "")
        parts = excl.split(":")
        nonempty = [p for p in parts if p]
        check(any(".backups" in p for p in nonempty), "clamav: backup dir excluded from scans")
        check(any("incomplete" in p for p in nonempty), "clamav: incomplete download dir excluded from scans")
        # report dir is optional; if configured it must be excluded
        rd = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "clamav-config"][0]["data"].get("REPORT_DIR", "")
        if rd:
            check(any("clamav-reports" in p or rd in p for p in nonempty),
                  "clamav: report dir excluded from scans")
        for d in docs:
            if d["kind"] == "CronJob" and d["metadata"]["name"] in ("clamav-daily", "clamav-monthly"):
                env = [e["name"] for e in pod_spec(d)["containers"][0]["env"]]
                check("EXCLUDE_DIRS" in env, f"{d['metadata']['name']}: EXCLUDE_DIRS wired")

    # plex libraries are published for deploy.sh to consume
    check("plex-libraries" in cms, "plex-libraries ConfigMap rendered")

    # every long-running app has a startupProbe so slow boots aren't liveness-killed
    for d in workloads:
        if d["kind"] not in ("Deployment", "StatefulSet"):
            continue
        for c in pod_spec(d)["containers"]:
            if c["name"] in ("gluetun", "vpn-rotator"):
                continue
            check("startupProbe" in c, f'{d["metadata"]["name"]}/{c["name"]}: startupProbe present')

    # Plex transcode scratch: disk-backed emptyDir with a size cap, never tmpfs
    for d in workloads:
        if d["kind"] == "StatefulSet" and d["metadata"]["name"] == "plex":
            spec = pod_spec(d)
            tv = [v for v in spec["volumes"] if v["name"] == "transcode"]
            check(bool(tv) and "emptyDir" in tv[0], "plex: transcode emptyDir present")
            if tv:
                check(tv[0]["emptyDir"].get("medium") != "Memory", "plex: transcode NOT memory-backed (tmpfs counts against mem limit)")
                check(bool(tv[0]["emptyDir"].get("sizeLimit")), "plex: transcode sizeLimit set")
            tm = [m for c in spec["containers"] for m in c.get("volumeMounts", []) if m["mountPath"] == "/transcode"]
            check(bool(tm), "plex: /transcode mounted")

    # gluetun firewall must whitelist SABnzbd's inbound port (k8s sidecar requirement)
    for d in workloads:
        if d["metadata"]["name"] != "sabnzbd":
            continue
        g = [c for c in pod_spec(d)["containers"] if c["name"] == "gluetun"][0]
        env = {e["name"]: e.get("value") for e in g.get("env", [])}
        sab_port = [c for c in pod_spec(d)["containers"] if c["name"] == "sabnzbd"][0]["ports"][0]["containerPort"]
        check(env.get("FIREWALL_INPUT_PORTS") == str(sab_port),
              f"gluetun FIREWALL_INPUT_PORTS matches SABnzbd port ({sab_port})")

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
