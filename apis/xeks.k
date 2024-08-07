xrName = option("params")?.oxr?.metadata.name
providerConfigName = option("params")?.oxr?.spec.parameters.providerConfigName or "default"
deletionPolicy = option("params")?.oxr?.spec.parameters.deletionPolicy or "Delete"
region = option("params")?.oxr?.spec.parameters.region or ""
id = option("params")?.oxr?.spec.parameters.id or ""

role = {
  apiVersion = "iam.aws.upbound.io/v1beta1"
  kind = "Role"
  metadata.name = xrName + "-iam-role"
  metadata.labels = {
    "role" = "controlplane"
  }
  spec.providerConfigRef.name = providerConfigName
  spec.deletionPolicy = deletionPolicy
  spec.forProvider.assumeRolePolicy = """{
          "Version": "2012-10-17",
          "Statement": [
              {
                  "Effect": "Allow",
                  "Principal": {
                      "Service": [
                          "eks.amazonaws.com"
                      ]
                  },
                  "Action": [
                      "sts:AssumeRole"
                  ]
              }
          ]
        }
      """
}

clusterRolePolicyAttachment = {
  apiVersion = "iam.aws.upbound.io/v1beta1"
  kind = "RolePolicyAttachment"
  metadata.name = xrName + "-cluster-role-policy-attachment"
  spec.providerConfigRef.name = providerConfigName
  spec.deletionPolicy = deletionPolicy
  spec.forProvider = {
    policyArn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
    roleSelector = {
      matchControllerRef = True
      matchLabels = {
        "role" = "controlplane"
      }
    }
  }
}

kubernetesVersion = option("params")?.oxr?.spec.parameters.version or ""
kubernetesCluster = {
  apiVersion = "eks.aws.upbound.io/v1beta1"
  kind = "Cluster"
  metadata.name = xrName + "-kubernetes-cluster"
  metadata.annotations = {
    "krm.kcl.dev/composition-resource-name" = "kubernetesCluster"
  }
  spec.providerConfigRef.name = providerConfigName
  spec.deletionPolicy = deletionPolicy
  spec.forProvider = {
    region = region
    version = kubernetesVersion
    roleArnSelector = {
      matchControllerRef = True
      matchLabels = {
        "role" = "controlplane"
      }
    }
    vpcConfig = [
      {
        endpointPrivateAccess = True
        subnetIdSelector.matchLabels = {
          "access" = "public"
          "networks.aws.platform.upbound.io/network-id" = id
        }
      }
    ]
  }
}

clusterSecurityGroupId = option("params")?.ocds?[kubernetesCluster.metadata.name]?.Resource?.status?.atProvider?.vpcConfig?[0]?.clusterSecurityGroupId or False
if clusterSecurityGroupId:
  clusterSecurityGroupImport = {
    apiVersion = "ec2.aws.upbound.io/v1beta1"
    kind = "SecurityGroup"
    metadata.name = clusterSecurityGroupId
    spec.providerConfigRef.name = providerConfigName
    spec.deletionPolicy = deletionPolicy
    spec.forProvider = {
      region = region
      tags = {
        "eks.aws.platform.upbound.io/discovery" = id
      }
    }
  }

uid = option("params")?.oxr?.metadata.uid or ""
connectionSecretNamespace = option("params")?.oxr?.spec.writeConnectionSecretToRef.namespace or "upbound-system"
kubernetesClusterAuth = {
  apiVersion = "eks.aws.upbound.io/v1beta1"
  kind = "ClusterAuth"
  metadata.name = xrName + "-cluster-auth"
  spec.providerConfigRef.name = providerConfigName
  spec.deletionPolicy = deletionPolicy
  spec.forProvider = {
    region = region
    clusterNameSelector.matchControllerRef = True
  }
  spec.writeConnectionSecretToRef = {
      name = "{}-ekscluster".format(uid)
      namespace = connectionSecretNamespace
  }
}

nodegroupRole = {
  apiVersion = "iam.aws.upbound.io/v1beta1"
  kind = "Role"
  metadata.name = xrName + "-nodegroup-role"
  metadata.labels = {
    "role" = "nodegroup"
  }
  spec.providerConfigRef.name = providerConfigName
  spec.deletionPolicy = deletionPolicy
  spec.forProvider.assumeRolePolicy = """{
          "Version": "2012-10-17",
          "Statement": [
              {
                  "Effect": "Allow",
                  "Principal": {
                      "Service": [
                          "ec2.amazonaws.com"
                      ]
                  },
                  "Action": [
                      "sts:AssumeRole"
                  ]
              }
          ]
        }
      """
}

nodeGroupRolePolicies = [
  "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
  "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
  "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
]

nodeGroupRolePolicyAttachments = [{
  apiVersion = "iam.aws.upbound.io/v1beta1"
  kind = "RolePolicyAttachment"
  metadata.name = xrName + "-nodegroup-rpa-{}".format(i)
  spec.providerConfigRef.name = providerConfigName
  spec.deletionPolicy = deletionPolicy
  spec.forProvider = {
    policyArn = p
    roleSelector = {
      matchControllerRef = True
      matchLabels = {
        "role" = "nodegroup"
      }
    }
  }
} for i, p in nodeGroupRolePolicies]


nodeCount = option("params")?.oxr?.spec.parameters.nodes.count or ""
instanceType = option("params")?.oxr?.spec.parameters.nodes.instanceType or ""
nodeGroupPublic = {
  apiVersion = "eks.aws.upbound.io/v1beta1"
  kind = "NodeGroup"
  metadata.name = xrName + "-nodegroup-public"
  metadata.annotations = {
    "krm.kcl.dev/composition-resource-name" = "nodeGroupPublic"
  }
  spec.providerConfigRef.name = providerConfigName
  spec.deletionPolicy = deletionPolicy
  spec.forProvider = {
    region = region
    clusterNameSelector.matchControllerRef = True
    nodeRoleArnSelector = {
      matchControllerRef = True
      matchLabels = {
        "role" = "nodegroup"
      }
    }
    scalingConfig = [{
      desiredSize = nodeCount
      maxSize = 100
      minSize = 1
    }]
    instanceTypes = [instanceType]
    subnetIdSelector.matchLabels = {
      "networks.aws.platform.upbound.io/network-id" = id
      "access" = "public"
    }
  }
}

cniAddon = {
  apiVersion = "eks.aws.upbound.io/v1beta1"
  kind = "Addon"
  metadata.name = xrName + "-cni-addon"
  metadata.annotations = {
    "krm.kcl.dev/composition-resource-name" = "cniAddon"
  }
  spec.providerConfigRef.name = providerConfigName
  spec.deletionPolicy = deletionPolicy
  spec.forProvider = {
    region = region
    addonName = "vpc-cni"
    clusterNameSelector.matchControllerRef = True
    configurationValues = '{"env": {"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG":"false"}}' # see https://github.com/aws/amazon-vpc-cni-k8s/blob/master/README.md for different options
  }
}

ebsCsiAddon = {
  apiVersion = "eks.aws.upbound.io/v1beta1"
  kind = "Addon"
  metadata.name = xrName + "-ebs-csi-addon"
  metadata.annotations = {
    "krm.kcl.dev/composition-resource-name" = "ebsCsiAddon"
  }
  spec.providerConfigRef.name = providerConfigName
  spec.deletionPolicy = deletionPolicy
  spec.forProvider = {
    region = region
    addonName = "aws-ebs-csi-driver"
    clusterNameSelector.matchControllerRef = True
  }
}

eksOidcIssuer = option("params")?.ocds?[kubernetesCluster.metadata.name]?.Resource?.status?.atProvider?.identity?[0]?.oidc?[0]?.issuer or ""
if len(eksOidcIssuer) > 0:
  oidcProvider = {
    apiVersion = "iam.aws.upbound.io/v1beta1"
    kind = "OpenIDConnectProvider"
    metadata.name = xrName + "-oidc-provider"
    spec.providerConfigRef.name = providerConfigName
    spec.deletionPolicy = deletionPolicy
    spec.forProvider = {
      clientIdList = ["sts.amazonaws.com"]
      thumbprintList = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
      url = eksOidcIssuer
    }
  }

providerConfigTypes = ["helm", "kubernetes"]
providerConfigs = [{
  apiVersion = "{}.crossplane.io/v1alpha1".format(t)
  kind = "ProviderConfig"
  metadata.name = id
  metadata.annotations = {
      "krm.kcl.dev/ready": "True"
      "krm.kcl.dev/composition-resource-name" = "providerConfig-" + t
  }
  spec.credentials = {
      secretRef = {
        name = "{}-ekscluster".format(uid)
        namespace = connectionSecretNamespace
        key = "kubeconfig"
      }
      source = "Secret"
    }
} for t in providerConfigTypes]

oidcArn = option("params")?.ocds?[kubernetesCluster.metadata.name]?.Resource?.status?.atProvider?.arn or ""
oidcHost = eksOidcIssuer.strip("https://") or ""
irsaSettings = {
  apiVersion = "kubernetes.crossplane.io/v1alpha2"
  kind = "Object"
  metadata.name = id + "-irsa-settings"
  spec.providerConfigRef.name = id
  spec.deletionPolicy = "Orphan"
  spec.forProvider = {
    manifest: {
      apiVersion = "v1"
      kind = "ConfigMap"
      metadata.namespace = "default"
      metadata.name = "{}-irsa-settings".format(id)
      data = {
        oidc_arn = oidcArn
        oidc_host = oidcHost
      }
    }
  }
}

nodeGroupRoleArn = option("params")?.ocds?[nodegroupRole.metadata.name]?.Resource?.status?.atProvider?.arn or ""
autoscalerArn = option("params")?.oxr?.spec.parameters.iam.autoscalerArn or ""
adminRoleArn = option("params")?.oxr?.spec.parameters.iam.roleArn or ""
adminUser = option("params")?.oxr?.spec.parameters.iam.userArn or ""
awsAuth = {
  apiVersion = "kubernetes.crossplane.io/v1alpha2"
  kind = "Object"
  metadata.name = id + "-aws-auth"
  spec.providerConfigRef.name = id
  spec.deletionPolicy = "Orphan"
  spec.forProvider = {
    manifest: {
      apiVersion = "v1"
      kind = "ConfigMap"
      metadata.namespace = "kube-system"
      metadata.name = "aws-auth"
      data = {
        mapRoles = """\
- groups:
  - system:bootstrappers
  - system:nodes
  rolearn: ${nodeGroupRoleArn}
  username: system:node:{{EC2PrivateDNSName}}
- groups:
  - system:bootstrappers
  - system:nodes
  rolearn: ${autoscalerArn}
  username: system:node:{{EC2PrivateDNSName}}
- groups:
  - system:masters
  rolearn: ${adminRoleArn}
  username: adminrole"""
        mapUsers = """\
- groups:
  - system:masters
  userarn: ${adminUser}
  username: adminuser"""
      }
    }
  }
}

connectionDetails = {
  apiVersion: "meta.krm.kcl.dev/v1alpha1"
  kind: "CompositeConnectionDetails"
  if kubernetesClusterAuth.metadata.name in option("params").ocds:
      data: {
          kubeconfig = option("params")?.ocds[kubernetesClusterAuth.metadata.name].ConnectionDetails.kubeconfig
      }
  else:
      data: {}
}

items = [
  role
  clusterRolePolicyAttachment
  kubernetesCluster
  clusterSecurityGroupImport
  kubernetesClusterAuth
  nodegroupRole
  nodeGroupPublic
  oidcProvider
  irsaSettings
  awsAuth
  connectionDetails
  cniAddon
  ebsCsiAddon
] + nodeGroupRolePolicyAttachments + providerConfigs
