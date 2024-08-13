xrName = option("params")?.oxr?.metadata.name
region = option("params")?.oxr?.spec.parameters.region or ""
id = option("params")?.oxr?.spec.parameters.id or ""

_metadata = lambda name: str -> any {
    { annotations = { "krm.kcl.dev/composition-resource-name" = name }}
}

_defaults ={
    deletionPolicy = option("params")?.oxr?.spec.parameters.deletionPolicy or "Delete"
    providerConfigRef.name = option("params")?.oxr?.spec.parameters.providerConfigName or "default"
}

_items = [{
  apiVersion = "iam.aws.upbound.io/v1beta1"
  kind = "Role"
  metadata = _metadata("controlplaneRole") | {
    labels: {
      role = "controlplane"
    }
  }
  spec: _defaults | {
    forProvider = {
      forceDetachPolicies = True
      managedPolicyArns = [
        "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
      ]
      assumeRolePolicy = """{
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
  }
}]

kubernetesVersion = option("params")?.oxr?.spec.parameters.version or ""
_items += [{
  apiVersion = "eks.aws.upbound.io/v1beta2"
  kind = "Cluster"
  metadata = _metadata("kubernetesCluster")
  spec: _defaults | {
    forProvider = {
      region = region
      version = kubernetesVersion
      roleArnSelector = {
        matchControllerRef = True
        matchLabels = {
          role = "controlplane"
        }
      }
      vpcConfig = {
        endpointPrivateAccess = True
        subnetIdSelector.matchLabels = {
          "networks.aws.platform.upbound.io/network-id" = id
          access = "public"
        }
      }
    }
  }
}]

clusterSecurityGroupId = option("params")?.ocds?.kubernetesCluster?.Resource?.status?.atProvider?.vpcConfig?.clusterSecurityGroupId or False
if clusterSecurityGroupId:
  _items += [{
    apiVersion = "ec2.aws.upbound.io/v1beta1"
    kind = "SecurityGroup"
    metadata = {
      annotations = {
        **_metadata("clusterSecurityGroupImport").annotations
        "crossplane.io/external-name" = clusterSecurityGroupId
      }
    }
    spec: _defaults | {
      forProvider = {
        region = region
        tags = {
          "eks.aws.platform.upbound.io/discovery" = id
        }
      }
    }
  }]

uid = option("params")?.oxr?.metadata.uid or ""
connectionSecretNamespace = option("params")?.oxr?.spec.writeConnectionSecretToRef.namespace or "upbound-system"
_items += [{
  apiVersion = "eks.aws.upbound.io/v1beta1"
  kind = "ClusterAuth"
  metadata = _metadata("kubernetesClusterAuth")
  spec: _defaults | {
    forProvider = {
      region = region
      clusterNameSelector.matchControllerRef = True
    }
    writeConnectionSecretToRef = {
      name = "{}-ekscluster".format(uid)
      namespace = connectionSecretNamespace
    }
  }
}]

_items += [{
  apiVersion = "iam.aws.upbound.io/v1beta1"
  kind = "Role"
  metadata = _metadata("nodegroupRole") | {
    labels = {
      role = "nodegroup"
    }
  }
  spec: _defaults | {
    forProvider = {
      forceDetachPolicies = True
      managedPolicyArns = [
        "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
        "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
        "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
        "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      ]
      assumeRolePolicy = """{
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
  }
}]

nodeCount = option("params")?.oxr?.spec.parameters.nodes.count or ""
instanceType = option("params")?.oxr?.spec.parameters.nodes.instanceType or ""
_items += [{
  apiVersion = "eks.aws.upbound.io/v1beta2"
  kind = "NodeGroup"
  metadata = _metadata("nodeGroupPublic")
  spec: _defaults | {
    initProvider = {
      scalingConfig = {
        desiredSize = nodeCount
      }
    }
    forProvider = {
      region = region
      clusterNameSelector.matchControllerRef = True
      nodeRoleArnSelector = {
        matchControllerRef = True
        matchLabels = {
          role = "nodegroup"
        }
      }
      scalingConfig = {
        maxSize = 100
        minSize = 1
      }
      instanceTypes = [instanceType]
      subnetIdSelector.matchLabels = {
        "networks.aws.platform.upbound.io/network-id" = id
        access = "public"
      }
    }
  }
}]

principalArn = option("params")?.oxr?.spec?.parameters?.iam?.principalArn or False
if principalArn :
  _items += [{
    apiVersion: "eks.aws.upbound.io/v1beta1"
    kind: "AccessEntry"
    metadata = _metadata("accessEntry")
    spec: _defaults | {
      forProvider = {
        region = region
        clusterNameSelector = {
          matchControllerRef = True
        }
        type = "STANDARD"
        if principalArn:
          principalArn = principalArn
      }
    }
  }]

if principalArn :
  _items += [{
    apiVersion: "eks.aws.upbound.io/v1beta1"
    kind: "AccessPolicyAssociation"
    metadata = _metadata("accessPolicyAssociation")
    spec: _defaults | {
      forProvider = {
        region = region
        accessScope: {
          type: "cluster"
        }
        clusterNameSelector = {
          matchControllerRef = True
        }
        policyArn: "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        principalArnSelector = {
          matchControllerRef = True
        }
      }
    }
  }]

addons = [
  {
    name: "aws-ebs-csi-driver",
  },
  {
    name: "vpc-cni"
    configurationValues: '{"env": {"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG":"false"}}' # see https://github.com/aws/amazon-vpc-cni-k8s/blob/master/README.md for different options
  },
  {
    name: "eks-pod-identity-agent"
  }
]

_items += [{
  apiVersion = "eks.aws.upbound.io/v1beta1"
  kind = "Addon"
  metadata = _metadata("{}-addon".format(a.name))
  spec: _defaults | {
    forProvider = {
      region = region
      addonName = a.name
      clusterNameSelector.matchControllerRef = True
      if "configurationValues" in a :
        configurationValues: a.configurationValues
    }
  }
} for a in addons]

providerConfigTypes = ["helm", "kubernetes"]
_items += [{
  apiVersion = "{}.crossplane.io/v1alpha1".format(t)
  kind = "ProviderConfig"
  metadata = {
    name = id
    annotations = {
      **_metadata("providerConfig-{}".format(t)).annotations
      "krm.kcl.dev/ready": "True"
    }
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

_items += [{
  apiVersion: "meta.krm.kcl.dev/v1alpha1"
  kind: "CompositeConnectionDetails"
  if "kubernetesClusterAuth" in option("params").ocds:
      data: {
          kubeconfig = option("params")?.ocds?.kubernetesClusterAuth?.ConnectionDetails.kubeconfig
      }
  else:
      data: {}
}]

items = _items