#!/usr/bin/env bash
# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

DIR=$(realpath "$(dirname "${BASH_SOURCE[0]}")")

source "${DIR}/helper.sh"

function main() {
  local all_releases=("${@}")
  for release in "${all_releases[@]}"; do
    name="test-kwokctl-descheduler-${release}"

    kwokctl create cluster --name "${name}" \
      --runtime=docker --enable descheduler \
      --extra-args=descheduler=descheduling-interval=10s

    kwokctl scale node --replicas 2 --name "${name}"

    api_ready=false
    for _ in {1..30}; do
      if kubectl get nodes >/dev/null 2>&1; then
        api_ready=true
        break
      fi
      sleep 2
    done
    if [[ "${api_ready}" != "true" ]]; then
      echo "Kubernetes API is not ready"
      exit 1
    fi

    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: descheduler-trigger-sa
---
apiVersion: v1
kind: Pod
metadata:
  name: descheduler-trigger-a
  labels:
    anchor: descheduler-trigger
    app: trigger-a
spec:
  serviceAccountName: descheduler-trigger-sa
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.10
---
apiVersion: v1
kind: Pod
metadata:
  name: descheduler-trigger-b
spec:
  serviceAccountName: descheduler-trigger-sa
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            anchor: descheduler-trigger
        topologyKey: kubernetes.io/hostname
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: trigger-violation
        topologyKey: kubernetes.io/hostname
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.10
EOF

    kubectl wait --for=jsonpath='{.status.phase}'=Running pod/descheduler-trigger-a --timeout=60s
    kubectl wait --for=jsonpath='{.status.phase}'=Running pod/descheduler-trigger-b --timeout=60s
    anchor_node="$(kubectl get pod descheduler-trigger-a -o jsonpath='{.spec.nodeName}')"
    violating_node="$(kubectl get pod descheduler-trigger-b -o jsonpath='{.spec.nodeName}')"
    if [[ "${anchor_node}" != "${violating_node}" ]]; then
      echo "Trigger pods are not on the same node"
      exit 1
    fi

    kubectl label pod descheduler-trigger-a app=trigger-violation --overwrite

    descheduler_triggered=false
    for _ in {1..60}; do
      if docker logs "kwok-${name}-descheduler" 2>&1 | grep -q 'Node has been classified'; then
        descheduler_triggered=true
        break
      fi
      sleep 2
    done

    if [[ "${descheduler_triggered}" != "true" ]]; then
      echo "Descheduler did not run balancing cycle"
      docker logs --tail 200 "kwok-${name}-descheduler" || true
      exit 1
    fi

    kwokctl delete cluster --name "${name}"
  done
}

requirements

mapfile -t releases < <(supported_releases)
main "${releases[@]}"
