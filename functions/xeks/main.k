import models.io.upbound.aws.ec2.v1beta1 as ec2v1beta1
import models.io.upbound.aws.eks.v1beta1 as eksv1beta1
import models.io.upbound.aws.eks.v1beta2 as eksv1beta2
import models.io.upbound.aws.iam.v1beta1 as iamv1beta1

xrName = option("params")?.oxr?.metadata.name
region = option("params")?.oxr?.spec.parameters.region or ""
id = option("params")?.oxr?.spec.parameters.id or ""
kubernetesVersion = option("params")?.oxr?.spec.parameters.version or ""
uid = option("params")?.oxr?.metadata.uid or ""

_metadata = lambda name: str -> any {
    {
        annotations = {"krm.kcl.dev/composition-resource-name" = name}
    }
}

_defaults = {
    deletionPolicy = option("params")?.oxr?.spec.parameters.deletionPolicy or "Delete"
    providerConfigRef.name = option("params")?.oxr?.spec.parameters.providerConfigName or "default"
}

_items = []

_items += [
    iamv1beta1.Role {
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
    }
    eksv1beta2.Cluster {
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
    }
]

clusterSecurityGroupId = option("params")?.ocds?.kubernetesCluster?.Resource?.status?.atProvider?.vpcConfig?.clusterSecurityGroupId or False
if clusterSecurityGroupId:
    _items += [
        ec2v1beta1.SecurityGroup {
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
        }
    ]

connectionSecretNamespace = option("params")?.oxr?.spec.writeConnectionSecretToRef.namespace or "upbound-system"
_items += [
    eksv1beta1.ClusterAuth{
        metadata = _metadata("kubeClusterAuth") # doesn't work with `kubernetesClusterAuth` or `kubernetesClusterAuthXXX` ???
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
    }
]

_items += [
    iamv1beta1.Role{
        metadata = _metadata("nodegroupRole") | {
            labels = {
                role = "nodegroup"
            }
        }
        spec: _defaults | {
            forProvider = {
                forceDetachPolicies = True
                managedPolicyArns = [
                    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
                    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
                    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
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
    }
]

nodeCount = option("params")?.oxr?.spec.parameters.nodes.count or ""
instanceType = option("params")?.oxr?.spec.parameters.nodes.instanceType or ""

_items += [
    eksv1beta2.NodeGroup{
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
    }
]

principalArn = option("params")?.oxr?.spec?.parameters?.iam?.principalArn or False

if principalArn:
    _items += [
        eksv1beta1.AccessEntry{
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
        }
    ]

if principalArn:
    _items += [
        eksv1beta1.AccessPolicyAssociation{
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
        }
    ]

addons = [
    {
        name: "aws-ebs-csi-driver"
    }
    {
        name: "vpc-cni"
        # see https://github.com/aws/amazon-vpc-cni-k8s/blob/master/README.md for different options
        configurationValues: '{"env": {"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG":"false"}}'
    }
    {
        name: "eks-pod-identity-agent"
    }
]

_items += [
    eksv1beta1.Addon{
        metadata = _metadata("{}-addon".format(a.name))
        spec: _defaults | {
            forProvider = {
                region = region
                addonName = a.name
                clusterNameSelector.matchControllerRef = True
                if "configurationValues" in a:
                    configurationValues: a.configurationValues
            }
        }
    } for a in addons
]

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
    if "kubeClusterAuth" in option("params").ocds:
        data: {
            kubeconfig = option("params")?.ocds?.kubeClusterAuth?.ConnectionDetails?.kubeconfig
        }
    else:
        data: {}
}]

items = _items
