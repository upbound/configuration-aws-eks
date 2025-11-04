import models.io.upbound.awsm.ec2.v1beta1 as ec2v1beta1
import models.io.upbound.awsm.eks.v1beta1 as eksv1beta1
import models.io.upbound.awsm.iam.v1beta1 as iamv1beta1
import models.io.crossplane.kubernetesm.v1alpha1 as k8sv1alpha1
import models.io.crossplane.helmm.v1beta1 as helmv1beta1
import regex
import crypto

oxr = option("params").oxr # observed composite resource
_ocds = option("params").ocds # observed composed resources
_dxr = option("params").dxr # desired composite resource
dcds = option("params").dcds # desired composed resources

params = oxr.spec.parameters

xrName = oxr.metadata.name
uid = oxr.metadata.uid or ""

_metadata = lambda name: str -> any {
    {
        annotations = {"krm.kcl.dev/composition-resource-name" = name}
    }
}

ready = lambda o: any, statusPath = "atProvider" -> bool {
    status = o?.Resource?.status
    objstatus = status?.conditions or []
    len(objstatus) > 0 and all_true([c.status == "True" for c in objstatus]) and status and statusPath in status
}

exists: (str) -> bool = lambda o: str -> bool {
    resource = get(_ocds, o, {})
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
    managementPolicies = params.managementPolicies or ["*"]
    if params.providerConfigName:
        providerConfigRef = {
            kind = "ProviderConfig"
            name = params.providerConfigName
        }
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
    eksv1beta1.Cluster {
        metadata = _metadata("kubernetesCluster")
        spec: _defaults | {
            forProvider = {
                region = params.region
                version = params.kubernetesVersion
                accessConfig = {
                    authenticationMode = params.accessConfig.authenticationMode
                    bootstrapClusterCreatorAdminPermissions = params.accessConfig.bootstrapClusterCreatorAdminPermissions
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
                        "networks.aws.platform.upbound.io/network-id" = params.id
                        access = "public"
                    }
                }
            }
        }
    }
]

clusterSecurityGroupId = _ocds?.kubernetesCluster?.Resource?.status?.atProvider?.vpcConfig?.clusterSecurityGroupId or False
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
                    region = params.region
                    tags = {
                        "eks.aws.platform.upbound.io/discovery" = params.id
                    }
                }
            }
        }
    ]

if ready(get(_ocds, "kubernetesCluster", "")) or exists("kubernetesClusterAuth"):
    _items += [
        eksv1beta1.ClusterAuth {
            metadata = _metadata("kubernetesClusterAuth")
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    clusterNameSelector.matchControllerRef = True
                }
                writeConnectionSecretToRef = {
                    name = "{}-ekscluster".format(uid)
                }
            }
        }
    ]

_items += [
    iamv1beta1.Role {
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

if ready(get(_ocds, "vpc-cni-addon", "")) or exists("nodeGroupPublic"):
    _items += [
        eksv1beta1.NodeGroup {
            metadata = _metadata("nodeGroupPublic")
            spec: _defaults | {
                initProvider = {
                    scalingConfig = {
                        desiredSize = nodeCount
                    }
                }
                forProvider = {
                    region = params.region
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
                        "networks.aws.platform.upbound.io/network-id" = params.id
                        access = "public"
                    }
                }
            }
        }
    ]

principalArn = oxr.spec?.parameters?.iam?.principalArn or False

if principalArn:
    _items += [
        eksv1beta1.AccessEntry {
            # force recreate when principalArn changes
            metadata = _metadata(crypto.sha256("accessEntry-{}".format(principalArn)))
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    clusterNameSelector = {
                        matchControllerRef = True
                    }
                    type = "STANDARD"
                    principalArn = principalArn
                }
            }
        }
        eksv1beta1.AccessPolicyAssociation {
            # force recreate when principalArn changes
            metadata = _metadata(crypto.sha256("accessPolicyAssociation-{}".format(principalArn)))
            spec: _defaults | {
                forProvider = {
                    region = params.region
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

if ready(get(_ocds, "kubernetesClusterAuth", {})) or exists("vpc-cni-addon"):
    _items += [
        eksv1beta1.Addon {
            metadata = _metadata("vpc-cni-addon")
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    addonName = "vpc-cni"
                    clusterNameSelector.matchControllerRef = True
                    # see https://github.com/aws/amazon-vpc-cni-k8s/blob/master/README.md for different options
                    configurationValues: '{"env": {"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG":"false"}}'
                }
            }
        }
    ]

_items += [
    iamv1beta1.Role {
        metadata = _metadata("ebsCSIDriverRole") | {
            labels = {
                role = "ebs-csi-driver"
            }
        }
        spec: _defaults | {
            forProvider = {
                forceDetachPolicies = True
                managedPolicyArns = [
                    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
                ]
                assumeRolePolicy = """{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
"""
            }
        }
    }
]

_items += [
    eksv1beta1.PodIdentityAssociation {
        metadata = _metadata("ebsCSIDriverPodIdentityAssociation")
        spec: _defaults | {
            forProvider = {
                region = params.region
                clusterNameSelector.matchControllerRef = True
                namespace = "kube-system"
                serviceAccount = "ebs-csi-controller-sa"
                roleArnSelector = {
                    matchControllerRef = True
                    matchLabels = {
                        role = "ebs-csi-driver"
                    }
                }
            }
        }
    }
]

if (ready(get(_ocds, "ebsCSIDriverPodIdentityAssociation", "")) and ready(get(_ocds, "nodeGroupPublic", ""))) or exists("aws-ebs-csi-driver-addon"):
    _items += [
        eksv1beta1.Addon {
            metadata = _metadata("aws-ebs-csi-driver-addon")
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    addonName = "aws-ebs-csi-driver"
                    clusterNameSelector.matchControllerRef = True
                    configurationValues = '{"defaultStorageClass": {"enabled": true}}'
                }
            }
        }
    ]

if ready(get(_ocds, "nodeGroupPublic", "")) or exists("eks-pod-identity-agent"):
    _items += [
        eksv1beta1.Addon {
            metadata = _metadata("eks-pod-identity-agent-addon")
            spec: _defaults | {
                forProvider = {
                    region = params.region
                    addonName = "eks-pod-identity-agent"
                    clusterNameSelector.matchControllerRef = True
                }
            }
        }
    ]

_items += [
    k8sv1alpha1.ProviderConfig {
        metadata = {
            name = params.id
            generateName = "{}-".format(params.id)
            annotations = {
                **_metadata("providerConfig-kubernetes").annotations
                "krm.kcl.dev/ready": "True"
            }
        }
        spec.credentials = {
            secretRef = {
                name = "{}-ekscluster".format(uid)
                namespace = oxr.metadata.namespace
                key = "kubeconfig"
            }
            source = "Secret"
        }
    }
]

_items += [
    helmv1beta1.ProviderConfig {
        metadata = {
            name = params.id
            generateName = "{}-".format(params.id)
            annotations = {
                **_metadata("providerConfig-helm").annotations
                "krm.kcl.dev/ready": "True"
            }
        }
        spec.credentials = {
            secretRef = {
                name = "{}-ekscluster".format(uid)
                namespace = oxr.metadata.namespace
                key = "kubeconfig"
            }
            source = "Secret"
        }
    }
]

_items += [{
    apiVersion: "meta.krm.kcl.dev/v1alpha1"
    kind: "CompositeConnectionDetails"
    if "kubernetesClusterAuth" in _ocds:
        data: {
            kubeconfig = _ocds?.kubernetesClusterAuth?.ConnectionDetails?.kubeconfig
        }
    else:
        data: {}
}]

# Update the dxr status.
_dxr = _dxr | {
    status: {
        eks: {
            clusterName: _ocds["kubernetesCluster"]?.Resource?.metadata?.name
            nodeGroupArn: _ocds["nodeGroupPublic"]?.Resource?.status?.atProvider?.arn
        }
    }
}

_items += [_dxr]

items = _items