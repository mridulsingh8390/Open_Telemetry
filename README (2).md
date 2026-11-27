# Runbook: monitor EKS with OpenTelemetry, Prometheus, Loki, Tempo and Grafana on EC2

Two scripts, run in two places:

| Script | Run it on | What it does |
|---|---|---|
| `02-setup-eks-monitoring.sh` | A machine where `kubectl`, `helm` and `aws` work against the EKS cluster | Installs OpenTelemetry Collector, Prometheus, Loki, Tempo on EKS and prints 3 URLs |
| `01-setup-grafana-ec2.sh` | The Grafana EC2 instance (over SSH) | Installs Grafana + Apache reverse proxy on **port 80**, adds the 3 data sources |

> Both scripts were written from the upstream docs and tested for syntax and rendering only, not against a live account.
> Do the first run in a test environment, step by step, and keep this runbook open.

---

## 1. How it fits together

```
 Your apps ──OTLP──► OTel Collector (DaemonSet, every node)
                          │ metrics ─► Prometheus ─┐
                          │ logs    ─► Loki ───────┼─ internal NLBs (:9090 :3100 :3200)
                          └ traces  ─► Tempo ──────┘            │
              EKS cluster (Loki + Tempo data in S3)             │ private network
                                                                ▼
 Browser ──► http://<ec2>:80 ──► Apache ──► Grafana (127.0.0.1:3000) ──► the 3 data sources
                                  Grafana EC2 (you create it, SSH access)
```

Order: **02 first** (it prints the URLs), then **01**.

---

## 2. Before you start (checklist)

**For script 02**
- [ ] An EKS cluster with **at least 2 nodes of 4 vCPU / 8 GB** (for example `t3.xlarge`). `t3.large × 2` is too small.
- [ ] Two **private subnets** (2 AZs) tagged `kubernetes.io/role/internal-elb=1` (the internal load balancers use them).
- [ ] `aws`, `kubectl`, `helm`, `curl` installed, and an AWS identity that can manage EKS, IAM, S3, EC2 security groups and ELB.
- [ ] `kubectl get nodes` works from that machine. If the cluster endpoint is private, run it from a host inside the VPC.

**For script 01**
- [ ] An EC2 instance you created: Amazon Linux 2023 or Ubuntu, `t3.small` or bigger, 20 GB disk.
- [ ] It is in the **same VPC as the cluster** (or a VPC peered/connected to it) so it can reach the internal load balancers.
- [ ] Outbound internet (to install packages).
- [ ] Security group inbound: **TCP 80** from the people who will use Grafana, and TCP 22 for your SSH.
- [ ] Do **not** open port 3000. Grafana listens on `127.0.0.1` only; Apache is the only way in.

---

## 3. Part A – EKS side (script 02)

### A1. Get the files and set the variables

Copy `02-setup-eks-monitoring.sh` to the machine, then edit the CONFIG block at the top:

| Variable | Default | Change it when |
|---|---|---|
| `REGION` | `us-east-1` | your cluster is elsewhere |
| `CLUSTER` | `demo-eks` | your cluster has another name |
| `AWS_PROFILE_NAME` | empty | you use a named AWS CLI profile |
| `ALLOW_CIDR` | empty (whole VPC) | the Grafana EC2 is in another network, e.g. `10.20.5.10/32` |
| `INSTALL_OTEL_OPERATOR` | `false` | you want auto-instrumentation of apps |

```bash
chmod +x 02-setup-eks-monitoring.sh
./02-setup-eks-monitoring.sh list        # shows the steps
```

### A2. Run it

```bash
./02-setup-eks-monitoring.sh
```

It runs these steps, in order, and each one checks itself:

| Step | What it does |
|---|---|
| `prereqs` | checks tools and cluster access, adds Helm repos |
| `addons` | EKS Pod Identity agent, EBS CSI driver, gp3 storage class |
| `s3iam` | two S3 buckets (Loki, Tempo) and an IAM role for them |
| `lbc` | AWS Load Balancer Controller |
| `prometheus` | Prometheus, Alertmanager, kube-state-metrics, node-exporter |
| `loki` | Loki (logs, stored in S3) |
| `tempo` | Tempo (traces, stored in S3) |
| `operator` | optional: cert-manager + OpenTelemetry Operator |
| `collector` | OpenTelemetry Collector on every node |
| `nlb` | 3 internal load balancers + security group rules, prints the URLs |
| `test` | sends sample metrics, logs and traces |
| `status` | shows pods and load balancers |

To go one step at a time (recommended the first time):

```bash
./02-setup-eks-monitoring.sh run prereqs
./02-setup-eks-monitoring.sh run addons
./02-setup-eks-monitoring.sh run s3iam lbc
./02-setup-eks-monitoring.sh run prometheus
./02-setup-eks-monitoring.sh run loki tempo
./02-setup-eks-monitoring.sh run collector
./02-setup-eks-monitoring.sh run nlb
```

**You are done with Part A when** `kubectl -n monitoring get pods` shows everything `Running`, and the `nlb` step printed:

```
PROMETHEUS_URL="http://k8s-....elb.us-east-1.amazonaws.com:9090"
LOKI_URL="http://k8s-....elb.us-east-1.amazonaws.com:3100"
TEMPO_URL="http://k8s-....elb.us-east-1.amazonaws.com:3200"
```

Copy those 3 lines. You can print them again any time with `./02-setup-eks-monitoring.sh urls`.

---

## 4. Part B – Grafana on EC2 (script 01)

### B1. Put the script on the EC2 and edit the CONFIG block

```bash
scp 01-setup-grafana-ec2.sh ec2-user@<ec2-ip>:~      # use ubuntu@ on Ubuntu
ssh ec2-user@<ec2-ip>
chmod +x 01-setup-grafana-ec2.sh
nano 01-setup-grafana-ec2.sh
```

Set:
- `GRAFANA_ADMIN_PASSWORD`: your own strong password (8+ characters). **Required.**
- `PROMETHEUS_URL`, `LOKI_URL`, `TEMPO_URL`: the 3 lines from Part A.
- `SERVER_NAME`: leave empty to use the instance's IP, or put a DNS name.

### B2. Run it

```bash
./01-setup-grafana-ec2.sh
```

It will:
1. install Grafana OSS and Apache (`httpd` on Amazon Linux, `apache2` on Ubuntu),
2. make Grafana listen on `127.0.0.1:3000` only,
3. write the 3 data sources,
4. set the admin password,
5. configure Apache as a reverse proxy: **port 80 → Grafana** (including WebSocket for Grafana Live),
6. check that `http://127.0.0.1/login` answers through Apache, and that the 3 backends are reachable.

### B3. Open Grafana

Browse to `http://<ec2-ip>/` and log in with `admin` and your password.

**Data sources are in:** Connections → Data sources. Open each one and click **Save & test**; you need a green result.

### If you ran script 01 before script 02

That is fine. Leave the three URLs as `<PASTE_...>`; the script installs everything and warns that no data sources exist yet. After Part A, paste the URLs and run:

```bash
./01-setup-grafana-ec2.sh datasources
```

---

## 5. Part C – Prove it works

On the machine from Part A:

```bash
./02-setup-eks-monitoring.sh run test
```

This runs a 60-second job that sends sample metrics, logs and traces. In Grafana, open **Explore** and try:

| Data source | Query | Expect |
|---|---|---|
| Prometheus | `up` | rows with value `1` |
| Loki | `{service_name="demo-service"}` | log lines |
| Tempo | Search → Service Name = `demo-service` | traces |

If all three show data, the whole pipeline works.

**Dashboards:** download the JSON from grafana.com (IDs `15757`, `15760`, `15758`, `1860`), then Dashboards → New → Import → Upload JSON file, and choose the Prometheus data source.

**Send your real apps' telemetry** to the Collector inside the cluster:
- OTLP gRPC: `otel-agent.monitoring.svc:4317`
- OTLP HTTP: `otel-agent.monitoring.svc:4318`

---

## 6. Troubleshooting

| Symptom | Where | Fix |
|---|---|---|
| `kubectl cannot reach the cluster` | 02 | Run from a host inside the VPC, or allow your IP in the cluster's public access CIDRs |
| Pods `Pending`, PVC unbound | 02 | EBS CSI: `kubectl -n kube-system get pods \| grep ebs`; re-run `./02... run addons` |
| Loki/Tempo `AccessDenied` or crash | 02 | Pod Identity link: re-run `run s3iam`, then `kubectl -n monitoring delete pod loki-0 tempo-0` |
| Load balancer has no address | 02 | `kubectl -n kube-system logs deploy/aws-load-balancer-controller`; check the `internal-elb` subnet tag |
| Collector log errors (`connection refused`, unknown field) | 02 | `kubectl -n monitoring logs ds/otel-agent --tail=50`; compare with the values in `monitoring-work/otel-agent-values.yaml` |
| Script 01: backends return `000` or timeout | 01 | EC2 cannot reach the NLB: same VPC? Cluster security group rule (script 02 `nlb` step; use `ALLOW_CIDR` for another network); NLB targets healthy in the EC2 console |
| Browser cannot open `http://<ec2-ip>/` | 01 | EC2 security group must allow TCP 80 from you |
| Apache 503 / "Service Unavailable" | 01 | `sudo systemctl status grafana-server`; on RHEL-like systems SELinux (script sets it), `sudo tail /var/log/httpd/grafana-error.log` |
| Data source "Save & test" fails | 01 | Run `./01... datasources` after fixing the URL; test with `curl http://<NLB>:9090/-/ready` from the EC2 |
| Forgot the admin password | 01 | Set a new one in the script and re-run it |

Useful commands:

```bash
# EKS side
kubectl -n monitoring get pods
kubectl -n monitoring get svc prometheus-internal loki-internal tempo-internal
./02-setup-eks-monitoring.sh run status

# Grafana EC2
sudo systemctl status grafana-server httpd        # apache2 on Ubuntu
sudo journalctl -u grafana-server -n 50
sudo tail -30 /var/log/httpd/grafana-error.log    # /var/log/apache2/ on Ubuntu
```

---

## 7. Operating it

- **Re-running is safe.** Both scripts skip what already exists. After editing a setting, re-run the script (or `run <step>`).
- **Change a URL** (for example the NLB was recreated): edit it in script 01, then `./01-setup-grafana-ec2.sh datasources`.
- **Retention** is 7 days (`RETENTION_HOURS`, `PROM_RETENTION` in script 02). Longer retention costs more S3 and EBS.
- **Back up Grafana:** snapshot the EC2 disk, or copy `/var/lib/grafana`.
- **Update Grafana:** `sudo dnf update grafana` (or `sudo apt-get install --only-upgrade grafana`).
- **HTTPS:** this runbook serves plain HTTP on port 80. For anything beyond a lab, put a certificate on it (Apache + Let's Encrypt, or an ALB with an ACM certificate in front) and change `GF_SERVER_ROOT_URL` accordingly.
- **Cost drivers:** the worker nodes, EBS volumes, S3 storage, 3 load balancers and the Grafana EC2.

---

## 8. Remove everything

```bash
# EKS side: stack, load balancers, buckets, Pod Identity links (asks you to type the cluster name)
./02-setup-eks-monitoring.sh destroy
```

The script leaves a few things for you to delete if unwanted: the IAM roles/policies `<cluster>-obs-s3`, `<cluster>-lbc`, `<cluster>-ebs-csi`, the EKS add-ons, and the security group rules for ports 9090/3100/3200.

Grafana EC2: stop and delete the instance yourself (or just `sudo systemctl disable --now httpd grafana-server`).
