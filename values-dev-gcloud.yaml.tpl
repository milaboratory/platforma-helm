#
# NOTE: this values.yaml is not functional until you replace {{USER}} pattern with your 
#       own username
#
# How to use:
#   sed "s/{{USER}}/$USER/" values-dev-gcloud.yaml.tpl > values-dev.yaml
#   helm upgrade --install "dev-$USER" platforma/platforma --values values-dev.yaml --namespace dev-gke
#

docker:
  enabled: true
  resources:
    limits:
      cpu: 8
      memory: 16Gi

image:
  repository: europe-west3-docker.pkg.dev/mik8s-euwe3-prod-gke-project/pl/pl
  pullPolicy: Always
  tag: "main" # or Chart.AppVersion

serviceAccount:
  create: false
  name: "platforma-ci-sa"

service:
  type: LoadBalancer # ClusterIP, NodePort, LoadBalancer
  annotations:
    external-dns.alpha.kubernetes.io/hostname: {{USER}}-dev.gcp.milaboratories.com

env:
  secretVariables:
    - name: PL_LICENSE
      secretKeyRef:
        name: pl-license-secret
        key: pl-license-key

deployment:
  redeployOnUpgrade: true

logging:
  destination: "dir:///var/log/platforma"
  persistence:
    enabled: true

persistence:
  mainRoot:
    enabled: false

  dbDir:
    enabled: true
    storageClass: "standard-rwo"
    mountPath: /data/rocksdb

artifactRegistry: "https://mi-test-assets.storage.googleapis.com/pub/assets/"

gcp:
  gar: "europe-west3-docker.pkg.dev/mik8s-euwe3-prod-gke-project/pl-containers/milaboratories/pl-containers"
  serviceAccount: "mik8s-platforma-ci-access@mik8s-euwe3-prod-gke-project.iam.gserviceaccount.com"
  projectId: "mik8s-euwe3-prod-gke-project"

primaryStorage:
  s3:
    enabled: false
  
  gcs:
    enabled: true
    url: "gs://mik8s-platforma-ci-euwe3-dev-gke/dev/{{USER}}/primary/" # e.g., gs://<bucket>[/<prefix-in-bucket>]

dataLibrary:
  s3:
    - id: "library"
      enabled: false

  gcs:
    - id: "library"
      enabled: true
      url: "gs://mik8s-platforma-library-euwe3-prod-gke/"
    - id: "test-assets"
      enabled: true
      url: "gs://mik8s-platforma-ci-euwe3-dev-gke/test-assets/"

authOptions:
  ldap:
    enabled: true
    server: "ldap://pl0-glauth.prod-pl0.svc.cluster.local:3893"
    dn: "cn=%u,ou=users,ou=users,dc=pldemo,dc=io"
  
extraArgs:
  - --skip-extended-self-check
  - --auth-sessions-gen=1

googleBatch:
  enabled: true
  region: "europe-west3"
  
  network: "projects/mik8s-euwe3-prod-gke-project/global/networks/mik8s-euwe3-prod-gke-vpc"
  subnetwork: "projects/mik8s-euwe3-prod-gke-project/regions/europe-west3/subnetworks/mik8s-euwe3-prod-gke-private-1"

  storage: "/data/nfs=nfs://10.244.108.130/nfs_share"
  volumes:
    enabled: true
    name: "nfs-volume"
    mountPath: "/data/nfs"
    workDirName: "dev/{{USER}}/work"
    packagesDirName: "dev/{{USER}}/packages"
    existingClaim: "filestore-ci-fast-pvc"

  jobNamePrefix: "dev-{{USER}}"
  provisioning: "SPOT"

monitoring:
  enabled: true

debug:
  enabled: true

# -- If you are struggling with the computer use either medium (4 cpu 16 gb) or large (8 cpu 32 gb)
#  nodeSelector:
#    node.milab.io/pool: large
#  tolerations:
#    - key: "dedicated"
#      operator: "Equal"
#      value: "large"
#      effect: "NoSchedule"
