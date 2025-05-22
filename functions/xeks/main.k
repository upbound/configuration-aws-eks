import models.io.upbound.aws.ec2.v1beta1 as ec2v1beta1
import models.io.upbound.aws.eks.v1beta1 as eksv1beta1
import models.io.upbound.aws.eks.v1beta2 as eksv1beta2
import models.io.upbound.aws.iam.v1beta1 as iamv1beta1
import regex

oxr = option("params").oxr
ocds = option("params").ocds

xrName = oxr.metadata.name
region = oxr.spec.parameters.region or ""
id = oxr.spec.parameters.id or ""
kubernetesVersion = oxr.spec.parameters.version or ""
uid = oxr.metadata.uid or ""
accessConfig = oxr.spec.parameters.accessConfig

_metadata = lambda name: str -> any {
    { annotations = { "krm.kcl.dev/composition-resource-name" = name }}
}

ready = lambda o: any, statusPath = "atProvider" -> bool {
    status = o?.Resource?.status
    objstatus = status?.conditions or []
    len(objstatus) > 0 and all_true([c.status == "True" for c in objstatus]) and status and statusPath in status
}

exists: (str) -> bool = lambda o: str -> bool {
    resource = get(ocds, o, {})
    resource != {}
}

get = lambda x: any, y: str, d: any -> any {
    """
            Get an item from a dictionary using a dot separated path.
            If the item is not found, return a default value.
            """
    p = regex.split(y, "\.")
    c = p[0]
    y = ".".join(p[1::])
    x[c] if len(p) == 1 and c in x else d if c not in x else get(x[c], y, d)
}

_defaults = {
    deletionPolicy = oxr.spec.parameters.deletionPolicy or "Delete"
    providerConfigRef.name = oxr.spec.parameters.providerConfigName or "default"
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
                accessConfig = {
                    authenticationMode = oxr.spec.parameters.accessConfig.authenticationMode
                    bootstrapClusterCreatorAdminPermissions = oxr.spec.parameters.accessConfig.bootstrapClusterCreatorAdminPermissions
                }
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

connectionSecretNamespace = oxr.spec.writeConnectionSecretToRef.namespace or "upbound-system"

if ready(get(ocds, "kubernetesCluster", "")) or exists("kubernetesCluster"):
    _items += [
        eksv1beta1.ClusterAuth{
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

nodeCount = oxr.spec.parameters.nodes.count or ""
instanceType = oxr.spec.parameters.nodes.instanceType or ""

if ready(get(ocds, "vpc-cni-addon", "")) or exists("vpc-cni-addon"):
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

principalArn = oxr.spec?.parameters?.iam?.principalArn or False

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
                    principalArn = principalArn
                }
            }
        }
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


if ready(get(ocds, "kubernetesClusterAuth", "")) or exists("kubernetesClusterAuth"):
    addonsPre = [
        {
            name: "vpc-cni"
            # see https://github.com/aws/amazon-vpc-cni-k8s/blob/master/README.md for different options
            configurationValues: '{"env": {"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG":"false"}}'
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
        } for a in addonsPre
    ]

if ready(get(ocds, "nodeGroupPublic", "")) or exists("nodeGroupPublic"):
    addonsPost = [
        {
            name: "aws-ebs-csi-driver"
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
        } for a in addonsPost
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
