#!/usr/bin/env bash
# =============================================================================
# 02-setup-eks-monitoring.sh      (run where kubectl + helm + aws CLI work against the EKS cluster)
#
# Installs the in-cluster monitoring stack:
#   OpenTelemetry Collector (DaemonSet) -> Prometheus (metrics), Loki (logs), Tempo (traces)
#   Loki + Tempo keep their data in S3.  Pods get AWS access through EKS Pod Identity.
#   3 internal load balancers (NLB) expose Prometheus/Loki/Tempo so the Grafana EC2 can reach them.
#
# Grafana itself is NOT installed here: use 01-setup-grafana-ec2.sh on the EC2 instance.
#
# Usage:
#   1) Review the CONFIG block (defaults work for cluster demo-eks in us-east-1)
#   2) chmod +x 02-setup-eks-monitoring.sh
#   3) ./02-setup-eks-monitoring.sh                 # run everything, in order
#      ./02-setup-eks-monitoring.sh list            # show the steps
#      ./02-setup-eks-monitoring.sh run loki tempo  # run only some steps
#      ./02-setup-eks-monitoring.sh from collector  # run from a step to the end
#      ./02-setup-eks-monitoring.sh urls            # print the 3 URLs for script 01 again
#      ./02-setup-eks-monitoring.sh destroy         # remove everything (asks first)
#
# Safe to re-run: every step checks whether the thing already exists.
# Progress/values are kept in ./monitoring-work/ (state.env + generated YAML).
# =============================================================================

# ----------------------------- CONFIG (edit me) ------------------------------
AWS_PROFILE_NAME=""                      # AWS CLI profile; leave empty to use the default credentials
REGION="us-east-1"                       # region of your EKS cluster
CLUSTER="demo-eks"                       # EKS cluster name
NS="monitoring"                          # Kubernetes namespace for the stack

# Which network may reach Prometheus/Loki/Tempo (ports 9090/3100/3200)?
# Empty = the whole VPC CIDR (right when the Grafana EC2 is in the same VPC).
# If the Grafana EC2 is elsewhere, put its CIDR here, e.g. 10.20.5.10/32
ALLOW_CIDR=""

INSTALL_OTEL_OPERATOR="false"            # true = also install cert-manager + OpenTelemetry Operator (auto-instrumentation)
RETENTION_HOURS="168"                    # Loki/Tempo retention (168h = 7 days)
PROM_RETENTION="7d"
PROM_STORAGE="30Gi"
# -----------------------------------------------------------------------------

set -Eeuo pipefail

WORK_DIR="${WORK_DIR:-$PWD/monitoring-work}"
STATE_FILE="$WORK_DIR/state.env"
mkdir -p "$WORK_DIR"
[ -f "$STATE_FILE" ] && source "$STATE_FILE" || touch "$STATE_FILE"

c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[36m'; c_0=$'\033[0m'
log()  { echo "${c_b}[$(date +%H:%M:%S)]${c_0} $*"; }
ok()   { echo "${c_g}  OK${c_0}  $*"; }
warn() { echo "${c_y}  WARN${c_0} $*"; }
die()  { echo "${c_r}  FAIL${c_0} $*" >&2; exit 1; }
trap 'echo "${c_r}Failed at line $LINENO. Fix the error above and re-run; finished steps are skipped.${c_0}" >&2' ERR

save() { # save KEY VALUE  -> persisted in state.env
  local k="$1" v="$2"
  grep -v "^export $k=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
  echo "export $k=\"$v\"" >> "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  export "$k=$v"
}

STEPS=(prereqs addons s3iam lbc prometheus loki tempo operator collector nlb test status)

# ------------------------------- helpers -------------------------------------
setup_env() {
  [ -n "$AWS_PROFILE_NAME" ] && export AWS_PROFILE="$AWS_PROFILE_NAME"
  export AWS_DEFAULT_REGION="$REGION"
  export KUBECONFIG="${KUBECONFIG:-$HOME/eks.kubeconfig}"

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
    || die "AWS credentials are not working. Set AWS_PROFILE_NAME or export keys."
  BUCKET_LOKI="${CLUSTER}-loki-${ACCOUNT_ID}"
  BUCKET_TEMPO="${CLUSTER}-tempo-${ACCOUNT_ID}"
  VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text) \
    || die "Cluster $CLUSTER not found in $REGION."
  VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
    --query 'Vpcs[0].CidrBlock' --output text)
  export ACCOUNT_ID BUCKET_LOKI BUCKET_TEMPO VPC_ID VPC_CIDR

  if ! kubectl get ns >/dev/null 2>&1; then
    aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --kubeconfig "$KUBECONFIG" >/dev/null
  fi
  kubectl get ns >/dev/null 2>&1 || die "kubectl cannot reach the cluster (private endpoint or IP not allowed?). Run this from a host inside the VPC."
}

role_exists()   { aws iam get-role --role-name "$1" >/dev/null 2>&1; }
policy_exists() { aws iam get-policy --policy-arn "$1" >/dev/null 2>&1; }

ensure_role() { # ensure_role NAME  (Pod Identity trust)
  if role_exists "$1"; then ok "role $1 exists"
  else aws iam create-role --role-name "$1" \
        --assume-role-policy-document "file://$WORK_DIR/pod-identity-trust.json" >/dev/null; ok "role $1 created"; fi
}

ensure_assoc() { # ensure_assoc NAMESPACE SERVICEACCOUNT ROLE_ARN
  local n; n=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --region "$REGION" \
      --namespace "$1" --service-account "$2" --query 'length(associations)' --output text)
  if [ "$n" != "0" ]; then ok "pod identity $1/$2 exists"
  else aws eks create-pod-identity-association --cluster-name "$CLUSTER" --region "$REGION" \
        --namespace "$1" --service-account "$2" --role-arn "$3" >/dev/null; ok "pod identity $1/$2 created"; fi
}

curl_in_cluster() { # curl_in_cluster URL
  kubectl -n "$NS" run "curl-$RANDOM" --rm -i --restart=Never --quiet \
    --image=curlimages/curl --command -- curl -s -m 10 "$1" 2>/dev/null | tr -d '\r'
}

# --------------------------------- steps -------------------------------------
step_prereqs() {
  log "Step: prerequisites"
  for t in aws kubectl helm curl; do command -v "$t" >/dev/null || die "$t is not installed."; done
  if ! command -v jq >/dev/null; then
    warn "jq missing, installing"; (sudo apt-get update -y && sudo apt-get install -y jq) >/dev/null 2>&1 || die "install jq manually"
  fi
  setup_env
  ok "account $ACCOUNT_ID, cluster $CLUSTER, vpc $VPC_ID ($VPC_CIDR)"

  cat > "$WORK_DIR/pod-identity-trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
JSON

  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
  local nodes cpu
  nodes=$(kubectl get nodes --no-headers | wc -l)
  cpu=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' | awk '{s+=$1} END{print s}')
  ok "nodes: $nodes, allocatable CPU: $cpu"
  if [ "${cpu%.*}" -lt 4 ] 2>/dev/null; then warn "Less than 4 allocatable vCPU: this stack will be tight. Use bigger nodes."; fi

  helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  ok "helm repos ready"
}

step_addons() {
  log "Step: Pod Identity agent, EBS CSI driver, gp3 StorageClass"
  setup_env
  if aws eks describe-addon --cluster-name "$CLUSTER" --region "$REGION" --addon-name eks-pod-identity-agent >/dev/null 2>&1; then
    ok "eks-pod-identity-agent exists"
  else
    aws eks create-addon --cluster-name "$CLUSTER" --region "$REGION" --addon-name eks-pod-identity-agent >/dev/null
  fi
  aws eks wait addon-active --cluster-name "$CLUSTER" --region "$REGION" --addon-name eks-pod-identity-agent
  ok "pod identity agent active"

  ensure_role "${CLUSTER}-ebs-csi"
  aws iam attach-role-policy --role-name "${CLUSTER}-ebs-csi" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
  if aws eks describe-addon --cluster-name "$CLUSTER" --region "$REGION" --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
    ok "aws-ebs-csi-driver exists"
  else
    aws eks create-addon --cluster-name "$CLUSTER" --region "$REGION" --addon-name aws-ebs-csi-driver \
      --pod-identity-associations "serviceAccount=ebs-csi-controller-sa,roleArn=arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER}-ebs-csi" >/dev/null
  fi
  aws eks wait addon-active --cluster-name "$CLUSTER" --region "$REGION" --addon-name aws-ebs-csi-driver
  ok "EBS CSI driver active"

  cat <<'YAML' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
YAML
  kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
  ok "StorageClass gp3 is the default"
}

step_s3iam() {
  log "Step: S3 buckets + IAM role for Loki and Tempo"
  setup_env
  local B
  for B in "$BUCKET_LOKI" "$BUCKET_TEMPO"; do
    if aws s3api head-bucket --bucket "$B" >/dev/null 2>&1; then ok "bucket $B exists"; else
      if [ "$REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$B" --region "$REGION" >/dev/null
      else aws s3api create-bucket --bucket "$B" --region "$REGION" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null; fi
      ok "bucket $B created"
    fi
    aws s3api put-public-access-block --bucket "$B" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3api put-bucket-encryption --bucket "$B" --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  done

  cat > "$WORK_DIR/obs-s3-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket","s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::${BUCKET_LOKI}","arn:aws:s3:::${BUCKET_TEMPO}"] },
    { "Effect": "Allow", "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::${BUCKET_LOKI}/*","arn:aws:s3:::${BUCKET_TEMPO}/*"] }
  ]
}
JSON
  local pol="arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER}-obs-s3"
  if policy_exists "$pol"; then ok "policy exists"; else
    aws iam create-policy --policy-name "${CLUSTER}-obs-s3" --policy-document "file://$WORK_DIR/obs-s3-policy.json" >/dev/null; ok "policy created"; fi
  ensure_role "${CLUSTER}-obs-s3"
  aws iam attach-role-policy --role-name "${CLUSTER}-obs-s3" --policy-arn "$pol"
  ensure_assoc "$NS" loki  "arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER}-obs-s3"
  ensure_assoc "$NS" tempo "arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER}-obs-s3"
}

step_lbc() {
  log "Step: AWS Load Balancer Controller"
  setup_env
  local pol="arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER}-lbc"
  if ! policy_exists "$pol"; then
    curl -fsSL -o "$WORK_DIR/lbc-policy.json" \
      https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
    aws iam create-policy --policy-name "${CLUSTER}-lbc" --policy-document "file://$WORK_DIR/lbc-policy.json" >/dev/null
    ok "policy created"
  else ok "policy exists"; fi
  ensure_role "${CLUSTER}-lbc"
  aws iam attach-role-policy --role-name "${CLUSTER}-lbc" --policy-arn "$pol"
  ensure_assoc kube-system aws-load-balancer-controller "arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER}-lbc"

  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
    --set clusterName="$CLUSTER" --set region="$REGION" --set vpcId="$VPC_ID" \
    --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
    --wait --timeout 5m
  kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=180s
  ok "load balancer controller running"
}

step_prometheus() {
  log "Step: Prometheus (kube-prometheus-stack, Grafana off)"
  setup_env
  cat > "$WORK_DIR/prometheus-values.yaml" <<YAML
fullnameOverride: kps
grafana:
  enabled: false
defaultRules:
  create: true
alertmanager:
  enabled: true
prometheus:
  prometheusSpec:
    enableRemoteWriteReceiver: true
    retention: ${PROM_RETENTION}
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: ${PROM_STORAGE}
    resources:
      requests: { cpu: 300m, memory: 1Gi }
      limits:   { memory: 2Gi }
YAML
  helm upgrade --install kps prometheus-community/kube-prometheus-stack -n "$NS" \
    -f "$WORK_DIR/prometheus-values.yaml" --wait --timeout 10m
  kubectl -n "$NS" get svc kps-prometheus >/dev/null || die "service kps-prometheus not found"
  local r; r=$(curl_in_cluster "http://kps-prometheus.${NS}.svc:9090/-/ready" || true)
  if echo "$r" | grep -qi "ready"; then ok "Prometheus ready"; else warn "Prometheus ready check returned: $r"; fi
}

step_loki() {
  log "Step: Loki (logs, S3)"
  setup_env
  cat > "$WORK_DIR/loki-values.yaml" <<YAML
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  storage:
    type: s3
    bucketNames:
      chunks: ${BUCKET_LOKI}
      ruler: ${BUCKET_LOKI}
      admin: ${BUCKET_LOKI}
    s3:
      region: ${REGION}
  limits_config:
    allow_structured_metadata: true
    volume_enabled: true
    retention_period: ${RETENTION_HOURS}h
  compactor:
    working_directory: /var/loki/compactor
    retention_enabled: true
    delete_request_store: s3
serviceAccount:
  create: true
  name: loki
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    storageClass: gp3
    size: 10Gi
  resources:
    requests: { cpu: 200m, memory: 512Mi }
backend:  { replicas: 0 }
read:     { replicas: 0 }
write:    { replicas: 0 }
gateway:  { enabled: false }
chunksCache:  { enabled: false }
resultsCache: { enabled: false }
lokiCanary:   { enabled: false }
test:         { enabled: false }
minio:        { enabled: false }
YAML
  helm upgrade --install loki grafana/loki -n "$NS" -f "$WORK_DIR/loki-values.yaml" --timeout 10m
  kubectl -n "$NS" rollout status statefulset/loki --timeout=300s
  local i r=""
  for i in 1 2 3 4 5 6; do r=$(curl_in_cluster "http://loki.${NS}.svc:3100/ready" || true); echo "$r" | grep -q ready && break; sleep 10; done
  if echo "$r" | grep -q ready; then ok "Loki ready"; else die "Loki not ready: '$r'. Check: kubectl -n $NS logs loki-0 (S3 / Pod Identity?)"; fi
}

step_tempo() {
  log "Step: Tempo (traces, S3)"
  setup_env
  cat > "$WORK_DIR/tempo-values.yaml" <<YAML
serviceAccount:
  create: true
  name: tempo
tempo:
  retention: ${RETENTION_HOURS}h
  storage:
    trace:
      backend: s3
      s3:
        bucket: ${BUCKET_TEMPO}
        endpoint: s3.${REGION}.amazonaws.com
        region: ${REGION}
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
persistence:
  enabled: true
  storageClassName: gp3
  size: 10Gi
YAML
  helm upgrade --install tempo grafana/tempo -n "$NS" -f "$WORK_DIR/tempo-values.yaml" --timeout 10m
  kubectl -n "$NS" rollout status statefulset/tempo --timeout=300s
  local i r=""
  for i in 1 2 3 4 5 6; do r=$(curl_in_cluster "http://tempo.${NS}.svc:3200/ready" || true); echo "$r" | grep -q ready && break; sleep 10; done
  if echo "$r" | grep -q ready; then ok "Tempo ready"; else die "Tempo not ready: '$r'. Check: kubectl -n $NS logs tempo-0"; fi
}

step_operator() {
  if [ "$INSTALL_OTEL_OPERATOR" != "true" ]; then log "Step: OTel Operator skipped (INSTALL_OTEL_OPERATOR=false)"; return 0; fi
  log "Step: cert-manager + OpenTelemetry Operator"
  setup_env
  helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
    --set crds.enabled=true --wait --timeout 5m
  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    -n opentelemetry-operator-system --create-namespace \
    --set manager.collectorImage.repository=otel/opentelemetry-collector-contrib --wait --timeout 5m
  ok "operator installed. To auto-instrument an app: create an Instrumentation CR in its namespace (see README Step 15) and add the inject annotation."
}

step_collector() {
  log "Step: OpenTelemetry Collector (DaemonSet otel-agent)"
  setup_env
  cat > "$WORK_DIR/otel-agent-values.yaml" <<YAML
mode: daemonset
fullnameOverride: otel-agent
image:
  repository: otel/opentelemetry-collector-contrib
command:
  name: otelcol-contrib
presets:
  logsCollection:
    enabled: true
    includeCollectorLogs: false
  kubeletMetrics:
    enabled: true
  kubernetesAttributes:
    enabled: true
resources:
  requests: { cpu: 100m, memory: 200Mi }
  limits:   { memory: 500Mi }
config:
  receivers:
    jaeger: null
    zipkin: null
    prometheus: null
    otlp:
      protocols:
        grpc: { endpoint: 0.0.0.0:4317 }
        http: { endpoint: 0.0.0.0:4318 }
  processors:
    batch: {}
  exporters:
    prometheusremotewrite:
      endpoint: http://kps-prometheus.${NS}.svc:9090/api/v1/write
      resource_to_telemetry_conversion:
        enabled: true
    otlphttp/loki:
      endpoint: http://loki.${NS}.svc:3100/otlp
    otlp/tempo:
      endpoint: tempo.${NS}.svc:4317
      tls:
        insecure: true
  service:
    pipelines:
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [prometheusremotewrite]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlphttp/loki]
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/tempo]
YAML
  helm upgrade --install otel-agent open-telemetry/opentelemetry-collector -n "$NS" \
    -f "$WORK_DIR/otel-agent-values.yaml" --timeout 5m
  kubectl -n "$NS" rollout status ds/otel-agent --timeout=300s
  sleep 15
  if kubectl -n "$NS" logs ds/otel-agent --tail=50 2>&1 | grep -Ei "connection refused|error.*export|unknown (receiver|processor)"; then
    warn "Collector log shows errors (above). Compare with README troubleshooting."
  else ok "Collector running, no export errors in the last log lines"; fi
}

step_nlb() {
  log "Step: internal NLBs so the Grafana EC2 can reach the backends"
  setup_env
  kubectl -n "$NS" get pods --show-labels | egrep 'prometheus-kps|loki-0|tempo-0' || true
  cat <<'YAML' | kubectl apply -n "$NS" -f -
apiVersion: v1
kind: Service
metadata:
  name: prometheus-internal
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
spec:
  type: LoadBalancer
  loadBalancerClass: service.k8s.aws/nlb
  selector:
    app.kubernetes.io/name: prometheus
    operator.prometheus.io/name: kps-prometheus
  ports:
    - { name: http, port: 9090, targetPort: 9090 }
---
apiVersion: v1
kind: Service
metadata:
  name: loki-internal
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
spec:
  type: LoadBalancer
  loadBalancerClass: service.k8s.aws/nlb
  selector:
    app.kubernetes.io/name: loki
    app.kubernetes.io/component: single-binary
  ports:
    - { name: http, port: 3100, targetPort: 3100 }
---
apiVersion: v1
kind: Service
metadata:
  name: tempo-internal
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
spec:
  type: LoadBalancer
  loadBalancerClass: service.k8s.aws/nlb
  selector:
    app.kubernetes.io/name: tempo
  ports:
    - { name: http, port: 3200, targetPort: 3200 }
YAML

  local svc host i
  for svc in prometheus loki tempo; do
    host=""
    for i in $(seq 1 40); do
      host=$(kubectl -n "$NS" get svc "${svc}-internal" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
      [ -n "$host" ] && break; sleep 10
    done
    [ -n "$host" ] || die "${svc}-internal has no load balancer address yet. Check: kubectl -n kube-system logs deploy/aws-load-balancer-controller (subnet tags?)"
    save "$(echo "$svc" | tr a-z A-Z)_HOST" "$host"
    ok "${svc}: $host"
  done

  local sg; sg=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
  local p out cidr="${ALLOW_CIDR:-$VPC_CIDR}"
  for p in 9090 3100 3200; do
    out=$(aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$sg" \
          --protocol tcp --port "$p" --cidr "$cidr" 2>&1) || echo "$out" | grep -q Duplicate || die "$out"
  done
  ok "security group $sg allows $cidr on 9090/3100/3200"
  warn "If your pods use custom networking with a separate security group, open those ports there too."
  step_urls
}

step_urls() {
  [ -n "${PROMETHEUS_HOST:-}" ] || die "Run the nlb step first."
  cat <<MSG

  ===== Paste these 3 lines into 01-setup-grafana-ec2.sh (CONFIG block) on the Grafana EC2 =====
  PROMETHEUS_URL="http://${PROMETHEUS_HOST}:9090"
  LOKI_URL="http://${LOKI_HOST}:3100"
  TEMPO_URL="http://${TEMPO_HOST}:3200"
  ================================================================================================
  Then on the EC2:  ./01-setup-grafana-ec2.sh datasources   (or run the whole script)
MSG
}

step_test() {
  log "Step: send test telemetry through the Collector"
  setup_env
  kubectl -n "$NS" delete job telemetrygen-traces telemetrygen-logs telemetrygen-metrics --ignore-not-found >/dev/null
  local sig
  for sig in traces logs metrics; do
    cat <<YAML | kubectl apply -n "$NS" -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: telemetrygen-${sig} }
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: gen
          image: ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest
          args: ["${sig}","--otlp-insecure","--otlp-endpoint","otel-agent.${NS}.svc:4317","--duration","60s","--rate","5","--service","demo-service"]
YAML
  done
  ok "jobs started (60s). In Grafana (Explore) you should see:"
  echo "      Prometheus: up        Loki: {service_name=\"demo-service\"}        Tempo: service = demo-service"
  echo "      Dashboards to import (JSON from grafana.com): 15757, 15760, 15758, 1860"
}

step_status() {
  log "Status"
  setup_env
  kubectl -n "$NS" get pods
  kubectl -n "$NS" get svc prometheus-internal loki-internal tempo-internal 2>/dev/null || true
}

step_destroy() {
  setup_env
  warn "This deletes the monitoring stack in the cluster, the 3 load balancers, S3 buckets (with data) and Pod Identity links. Your Grafana EC2 is not touched."
  read -r -p "Type the cluster name ($CLUSTER) to confirm: " a
  [ "$a" = "$CLUSTER" ] || die "cancelled"

  kubectl -n "$NS" delete svc prometheus-internal loki-internal tempo-internal --ignore-not-found || true
  sleep 30
  helm -n "$NS" uninstall otel-agent loki tempo kps 2>/dev/null || true
  helm -n opentelemetry-operator-system uninstall opentelemetry-operator 2>/dev/null || true
  helm -n cert-manager uninstall cert-manager 2>/dev/null || true
  helm -n kube-system uninstall aws-load-balancer-controller 2>/dev/null || true
  kubectl -n "$NS" delete pvc --all --ignore-not-found || true
  kubectl delete ns "$NS" --ignore-not-found || true

  aws s3 rb "s3://$BUCKET_LOKI" --force 2>/dev/null || true
  aws s3 rb "s3://$BUCKET_TEMPO" --force 2>/dev/null || true
  local sa id
  for sa in "$NS/loki" "$NS/tempo" "kube-system/aws-load-balancer-controller"; do
    id=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --region "$REGION" \
         --namespace "${sa%/*}" --service-account "${sa#*/}" --query 'associations[0].associationId' --output text 2>/dev/null || true)
    if [ -n "$id" ] && [ "$id" != "None" ]; then
      aws eks delete-pod-identity-association --cluster-name "$CLUSTER" --region "$REGION" --association-id "$id" >/dev/null || true
    fi
  done
  warn "Left in place (delete by hand if unwanted): IAM roles/policies ${CLUSTER}-obs-s3, ${CLUSTER}-lbc, ${CLUSTER}-ebs-csi, EKS add-ons, and the cluster-SG rules for ports 9090/3100/3200."
  rm -f "$STATE_FILE"
  ok "destroy finished"
}

# ---------------------------------- main -------------------------------------
cmd="${1:-all}"
case "$cmd" in
  list)    printf '%s\n' "${STEPS[@]}" ;;
  all)     for s in "${STEPS[@]}"; do "step_$s"; done; step_urls; log "Done." ;;
  run)     shift; [ $# -gt 0 ] || die "usage: $0 run <step> [step...]"; for s in "$@"; do declare -F "step_$s" >/dev/null || die "unknown step: $s"; "step_$s"; done ;;
  from)    shift; start="${1:-}"; [ -n "$start" ] || die "usage: $0 from <step>"; go=0
           for s in "${STEPS[@]}"; do [ "$s" = "$start" ] && go=1; [ "$go" = 1 ] && "step_$s"; done
           [ "$go" = 1 ] || die "unknown step: $start" ;;
  urls)    step_urls ;;
  destroy) step_destroy ;;
  *)       die "usage: $0 [all|list|run <steps>|from <step>|urls|destroy]" ;;
esac
