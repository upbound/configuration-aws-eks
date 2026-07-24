import models.io.upbound.awsm.ec2.v1beta1 as ec2v1beta1
import models.io.upbound.awsm.eks.v1beta1 as eksv1beta1
import models.io.upbound.awsm.iam.v1beta1 as iamv1beta1
import models.io.crossplane.kubernetesm.v1alpha1 as k8sv1alpha1
import models.io.crossplane.helmm.v1beta1 as helmv1beta1
import regex
import crypto
import json

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

_mgmtPolicies = ["Observe", "LateInitialize"] if (_importActive and not _commit) else \
    (["*"] if _importActive else (params.managementPolicies or ["*"]))

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

# Validation and drift detection for import mode
_requiredKeys = ["controlplaneRole","nodegroupRole","ebsCSIDriverRole","kubernetesCluster","nodeGroupPublic","vpcCniAddon","ebsCsiAddon","podIdentityAgentAddon","ebsCSIDriverPodIdentityAssociation"]
_requiredKeys += (["accessEntry","accessPolicyAssociation"] if principalArn else [])
_missing = [k for k in _requiredKeys if k not in _importResources] if _importActive else []
_blockRender = _importActive and len(_missing) > 0

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

# --- Generic import diff ----------------------------------------------------
# spec.forProvider is the source of truth; status.atProvider is live cloud state.
# Committing (managementPolicies -> ["*"]) converges live to desired, so the full
# set of changes a commit would make is a deep diff of forProvider vs atProvider,
# read straight off each observed managed resource. There is no per-field
# curation: any leaf the composition declares that the cloud disagrees with shows
# up automatically. Desired values are read from the OBSERVED resource's
# forProvider, which already carries the provider-injected defaults (e.g. the
# crossplane-* tags) and LateInitialized fields, so it reflects exactly what the
# provider would enforce on commit.
#
# Each change is classified using the only hardcoded knowledge left - a short
# list of leaf names that trace back to an editable XR parameter:
#   drift        - reconcilable by editing spec.parameters before commit; summed
#                  into driftCount ("drive this to what you intend, then commit").
#   sideEffects  - everything else a commit would do with no param knob (tag
#                  rewrites, composition/provider-fixed fields, immutable fields
#                  the provider will refuse to replace); summed into sideEffectCount.

# Composition-resource-name for each importable logical key (+ access* when an
# IAM principal is configured).
_importCR = {
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

# Leaf field names backed by an editable XR parameter (reconcilable drift).
# Everything else that differs is an unreconcilable side effect of committing.
_reconcilable = ["version", "authenticationMode", "instanceTypes", "desiredSize", "subnetIds"]

# Crossplane cross-resource wiring / provider-computed mirrors: never real cloud
# state, so skipping them avoids false positives.
_skipKey = lambda k: str -> bool {
    k.endswith("Ref") or k.endswith("Refs") or k.endswith("Selector") or k == "tagsAll"
}

# Bidirectional diff for open-keyed maps (tags): removals (live but not desired ->
# committing strips them) and additions/updates (desired but not live / changed).
# An omitted `desired` means "would be removed"; an omitted `observed` means
# "would be added".
_mapDiff = lambda fp: any, ap: any, path: str -> [any] {
    _rm = [{field = "{}[{}]".format(path, k), observed = ap[k]} for k in ap if k not in fp]
    _ch = [{field = "{}[{}]".format(path, k), desired = fp[k], observed = (ap[k] if k in ap else Undefined)} for k in fp if (k not in ap or ap[k] != fp[k])]
    _rm + _ch
}

# Scalar (order-insensitive) list handling: AWS set-like fields (subnetIds,
# managedPolicyArns, ...) come back from the cloud in a different order than the
# composition declares them, which is not a real change. Compare such lists as
# sets so ordering alone never registers as drift.
_isScalar = lambda v: any -> bool {
    typeof(v) in ["str", "int", "float", "bool"]
}
_scalarList = lambda v: any -> bool {
    typeof(v) == "list" and (all e in v { _isScalar(e) })
}
_sameSet = lambda a: any, b: any -> bool {
    len(a) == len(b) and (all e in a { e in b }) and (all e in b { e in a })
}

# JSON-string handling: many AWS fields (IAM assumeRolePolicy, addon
# configurationValues, ...) are JSON serialized into a string. The composition
# declares them pretty-printed / in one key order while the cloud returns them
# compacted / reordered, so a raw string compare reports formatting-only diffs.
# Detection is structural (no field-name list): a string is treated as JSON only
# if it opens like a JSON object - `{"...` or `{}` - which also rejects lookalikes
# such as Go templates (`{{ ... }}`). `[`-strings are intentionally NOT treated as
# JSON (e.g. `[INFO] ...` is not an array) to keep json.decode from ever seeing
# non-JSON (KCL has no way to recover from a decode error).
_looksJson = lambda s: str -> bool {
    regex.match(s, "^\\s*\\{\\s*(\"|\\})")
}
# Semantic equality via decode; KCL dict equality is key-order independent, so
# this collapses whitespace and key-order differences.
_jsonEqual = lambda a: str, b: str -> bool {
    json.decode(a) == json.decode(b)
}

# Deep diff driven by desired (forProvider). Recurses into nested objects, but
# only descends when the observed side is also an object - an absent observed
# subtree means the cloud does not report it, which is not a committable change.
_diffField = lambda k: str, dv: any, ov: any, path: str -> [any] {
    _jsonPair = typeof(dv) == "str" and typeof(ov) == "str" and _looksJson(dv) and _looksJson(ov)
    _listPair = _scalarList(dv) and _scalarList(ov)
    _valueChanged = (not _jsonEqual(dv, ov)) if _jsonPair else ((not _sameSet(dv, ov)) if _listPair else (dv != ov))
    _leafChanged = ov != Undefined and ov != None and _valueChanged
    _leaf = [{field = path, desired = dv, observed = ov}] if _leafChanged else []
    _obj = _deepDiff(dv, ov, path) if (typeof(dv) == "dict" and typeof(ov) == "dict") else _leaf
    _mapDiff(dv or {}, ov or {}, path) if k == "tags" else _obj
}
_deepDiff = lambda desired: any, observed: any, prefix: str -> [any] {
    sum([
        _diffField(k, desired[k], (observed[k] if (typeof(observed) == "dict" and k in observed) else Undefined), (prefix + "." + k if prefix != "" else k))
        for k in desired if not _skipKey(k)
    ], [])
}

# Full change set for one composition resource (empty until it is observed).
_diffFor = lambda cr: str -> [any] {
    _fp = get(_ocds, cr + ".Resource.spec.forProvider", Undefined)
    _ap = get(_ocds, cr + ".Resource.status.atProvider", Undefined)
    _deepDiff(_fp, _ap, "") if (typeof(_fp) == "dict" and typeof(_ap) == "dict") else []
}
_isReconcilable = lambda field: str -> bool {
    any p in _reconcilable { field.endswith(p) }
}
_resourceEntry = lambda key: str -> any {
    _cr = _importCR[key]
    _changes = _diffFor(_cr)
    {
        externalName = _importResources[key]
        observed = (get(_ocds, _cr + ".Resource.status.atProvider", Undefined) != Undefined)
        drift = [c for c in _changes if _isReconcilable(c.field)]
        sideEffects = [c for c in _changes if not _isReconcilable(c.field)]
    }
}

_reportKeys = [k for k in _importCR if k in _importResources]
_resources = {k: _resourceEntry(k) for k in _reportKeys} if (_importActive and not _blockRender) else {}
_driftLens = [len(_resources[k].drift) for k in _resources]
_driftCount = sum(_driftLens) if len(_driftLens) > 0 else 0
_sideEffectLens = [len(_resources[k].sideEffects) for k in _resources]
_sideEffectCount = sum(_sideEffectLens) if len(_sideEffectLens) > 0 else 0

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
            missing = _missing
        } | ({"error" = "import.resources is set but required external names are missing; render blocked until all are provided"} if _blockRender else {
            resources = _resources
            driftCount = _driftCount
            sideEffectCount = _sideEffectCount
        })
    } if _importActive else {})
}

_items += [_dxr]

items = [_dxr] if _blockRender else _items