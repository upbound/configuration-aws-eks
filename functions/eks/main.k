import models.io.upbound.awsm.ec2.v1beta1 as ec2v1beta1
import models.io.upbound.awsm.eks.v1beta1 as eksv1beta1
import models.io.upbound.awsm.iam.v1beta1 as iamv1beta1
import models.io.crossplane.kubernetesm.v1alpha1 as k8sv1alpha1
import models.io.crossplane.helmm.v1beta1 as helmv1beta1
import regex
import crypto
import importkit

oxr = option("params").oxr # observed composite resource
_ocds = option("params").ocds # observed composed resources
_dxr = option("params").dxr # desired composite resource
dcds = option("params").dcds # desired composed resources

params = oxr.spec.parameters

_import = params["import"] if "import" in params else {}
_importResources = _import["resources"] if "resources" in _import else {}
_importActive = len(_importResources) > 0
_commit = _import["commit"] if "commit" in _import else False

# Existing/remote network placement. When subnetIds is provided the cluster and node
# group use these subnets directly (existing VPC / brownfield); otherwise the composition
# selects subnets from a Network it composes (greenfield default).
_network = params["network"] if "network" in params else {}
_explicitSubnets = _network["subnetIds"] if "subnetIds" in _network else []
_explicitNodeSubnets = _network["nodeSubnetIds"] if "nodeSubnetIds" in _network else _explicitSubnets
_useExplicitNetwork = len(_explicitSubnets) > 0

xrName = oxr.metadata.name

_metadata = lambda name: str -> any {
    {
        annotations = {"krm.kcl.dev/composition-resource-name" = name}
    }
}

_extAnno = lambda key: str -> {str:str} {
    {"crossplane.io/external-name" = _importResources[key]} if (_importActive and key in _importResources) else {}
}
_metaImp = lambda name: str, key: str -> any {
    { annotations = {"krm.kcl.dev/composition-resource-name" = name} | _extAnno(key) }
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

_mgmtPolicies = importkit.managementPolicies(_importActive, _commit, params.managementPolicies or ["*"])

_defaults = {
    managementPolicies = _mgmtPolicies
    if params.providerConfigName:
        providerConfigRef = {
            kind = "ProviderConfig"
            name = params.providerConfigName
        }
}

_items = []

_items += [
    iamv1beta1.Role {
        metadata = _metaImp("controlplaneRole", "controlplaneRole") | {
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
        metadata = _metaImp("kubernetesCluster", "kubernetesCluster")
        spec: _defaults | {
            forProvider = {
                region = params.region
                version = params.version
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
                    # Explicit subnets (existing VPC / brownfield) take precedence. Otherwise
                    # select subnets from the composed Network by label (greenfield). We never
                    # use the selector in import mode because brownfield subnets are unlabelled.
                    if _useExplicitNetwork:
                        subnetIds = _explicitSubnets
                    if (not _useExplicitNetwork) and (not _importActive):
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

if _importActive or ready(get(_ocds, "kubernetesCluster", "")) or exists("kubernetesClusterAuth"):
    _items += [
        eksv1beta1.ClusterAuth {
            metadata = _metadata("kubernetesClusterAuth")
            spec: _defaults | {
                # ClusterAuth is a token generator with no importable external state and does
                # not support observe-only management policies, so it always runs normally.
                managementPolicies = params.managementPolicies or ["*"]
                forProvider = {
                    region = params.region
                    clusterNameSelector.matchControllerRef = True
                }
                writeConnectionSecretToRef = {
                    name = "{}-ekscluster".format(params.id)
                }
            }
        }
    ]

_items += [
    iamv1beta1.Role {
        metadata = _metaImp("nodegroupRole", "nodegroupRole") | {
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

if _importActive or ready(get(_ocds, "vpc-cni-addon", "")) or exists("nodeGroupPublic"):
    _items += [
        eksv1beta1.NodeGroup {
            metadata = _metaImp("nodeGroupPublic", "nodeGroupPublic")
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
                    # Explicit node subnets (existing VPC / brownfield) take precedence; node group
                    # subnets are immutable so for import they must match the existing node group.
                    if _useExplicitNetwork:
                        subnetIds = _explicitNodeSubnets
                    if (not _useExplicitNetwork) and (not _importActive):
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
            metadata = _metaImp(crypto.sha256("accessEntry-{}".format(principalArn)), "accessEntry")
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
            metadata = _metaImp(crypto.sha256("accessPolicyAssociation-{}".format(principalArn)), "accessPolicyAssociation")
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

if _importActive or ready(get(_ocds, "kubernetesClusterAuth", {})) or exists("vpc-cni-addon"):
    _items += [
        eksv1beta1.Addon {
            metadata = _metaImp("vpc-cni-addon", "vpcCniAddon")
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
        metadata = _metaImp("ebsCSIDriverRole", "ebsCSIDriverRole") | {
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
        metadata = _metaImp("ebsCSIDriverPodIdentityAssociation", "ebsCSIDriverPodIdentityAssociation")
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

if _importActive or (ready(get(_ocds, "ebsCSIDriverPodIdentityAssociation", "")) and ready(get(_ocds, "nodeGroupPublic", ""))) or exists("aws-ebs-csi-driver-addon"):
    _items += [
        eksv1beta1.Addon {
            metadata = _metaImp("aws-ebs-csi-driver-addon", "ebsCsiAddon")
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

if _importActive or ready(get(_ocds, "nodeGroupPublic", "")) or exists("eks-pod-identity-agent"):
    _items += [
        eksv1beta1.Addon {
            metadata = _metaImp("eks-pod-identity-agent-addon", "podIdentityAgentAddon")
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
                name = "{}-ekscluster".format(params.id)
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
                name = "{}-ekscluster".format(params.id)
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

# Import spec (EKS-specific) fed to the generic importkit engine below.
_requiredKeys = ["controlplaneRole","nodegroupRole","ebsCSIDriverRole","kubernetesCluster","nodeGroupPublic","vpcCniAddon","ebsCsiAddon","podIdentityAgentAddon","ebsCSIDriverPodIdentityAssociation"]
_requiredKeys += (["accessEntry","accessPolicyAssociation"] if principalArn else [])

# Read the observed Cluster / NodeGroup atProvider blocks (None until they
# sync). Surfacing these on the EKS status lets higher-level configurations
# (e.g. configuration-aws-ctp) read the OIDC issuer, cluster ARN and running
# node instance type from the EKS XR instead of composing their own
# observe-only Cluster / NodeGroup managed resources.
_clusterAtProvider = _ocds["kubernetesCluster"]?.Resource?.status?.atProvider
_ngAtProvider = _ocds["nodeGroupPublic"]?.Resource?.status?.atProvider

_identity = _clusterAtProvider?.identity or []
_oidcList = (_identity[0]?.oidc or []) if len(_identity) > 0 else []
_oidcIssuerUrl = (_oidcList[0]?.issuer or "") if len(_oidcList) > 0 else ""

_ngInstanceTypes = _ngAtProvider?.instanceTypes or []

# --- Generic import diff (delegated to the importkit module) ----------------
# The whole diff/classify/report engine lives in importkit.k (provider-agnostic,
# reusable). This composition only supplies the EKS-specific spec:
#   registry     - importable logical key -> composition-resource-name (+ access*
#                  when an IAM principal is configured).
#   reconcilable - leaf field names backed by an editable XR parameter; matching
#                  changes are reconcilable `drift`, everything else is a
#                  `sideEffect` that committing applies with no param knob.
_registry = {
    kubernetesCluster = "kubernetesCluster"
    nodeGroupPublic = "nodeGroupPublic"
    controlplaneRole = "controlplaneRole"
    nodegroupRole = "nodegroupRole"
    ebsCSIDriverRole = "ebsCSIDriverRole"
    vpcCniAddon = "vpc-cni-addon"
    ebsCsiAddon = "aws-ebs-csi-driver-addon"
    podIdentityAgentAddon = "eks-pod-identity-agent-addon"
    ebsCSIDriverPodIdentityAssociation = "ebsCSIDriverPodIdentityAssociation"
} | ({
    accessEntry = crypto.sha256("accessEntry-{}".format(principalArn))
    accessPolicyAssociation = crypto.sha256("accessPolicyAssociation-{}".format(principalArn))
} if principalArn else {})

_reconcilable = ["version", "authenticationMode", "instanceTypes", "desiredSize", "subnetIds"]

_report = importkit.buildReport({
    ocds = _ocds
    importResources = _importResources
    registry = _registry
    reconcilable = _reconcilable
    requiredKeys = _requiredKeys
}) if _importActive else {missing = [], blockRender = False, resources = {}, driftCount = 0, sideEffectCount = 0}

# Update the dxr status.
_dxr = _dxr | {
    status: {
        eks: {
            clusterName: _ocds["kubernetesCluster"]?.Resource?.metadata?.name
            clusterArn: _clusterAtProvider?.arn
            oidcIssuerUrl: _oidcIssuerUrl
            nodeGroupArn: _ngAtProvider?.arn
            nodeGroup: {
                instanceType: _ngInstanceTypes[0] if len(_ngInstanceTypes) > 0 else ""
            }
        }
    } | ({
        "import" = {
            active = True
            commit = _commit
            phase = ("Committing" if _commit else "Observing")
            missing = _report.missing
        } | ({"error" = "import.resources is set but required external names are missing; render blocked until all are provided"} if _report.blockRender else {
            resources = _report.resources
            driftCount = _report.driftCount
            sideEffectCount = _report.sideEffectCount
        })
    } if _importActive else {})
}

_items += [_dxr]

items = [_dxr] if _report.blockRender else _items