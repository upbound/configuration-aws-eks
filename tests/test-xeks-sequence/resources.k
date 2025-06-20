import models.io.crossplane.helm.v1alpha1 as helmv1alpha1
import models.io.crossplane.kubernetes.v1alpha1 as kubernetesv1alpha1
import models.io.upbound.aws.eks.v1beta1 as eksv1beta1
import models.io.upbound.aws.eks.v1beta2 as eksv1beta2
import models.io.upbound.aws.iam.v1beta1 as iamv1beta1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1

_kubernetesCluster = eksv1beta2.Cluster {
    metadata = {
        annotations = {
            "crossplane.io/composition-resource-name" = "kubernetesCluster"
        }
        generateName = "configuration-aws-eks-"
        labels = {
            "crossplane.io/composite" = "configuration-aws-eks"
        }
    }
    spec = {
        deletionPolicy = "Delete"
        forProvider = {
            region = "us-west-2"
            accessConfig = {
                authenticationMode = "API_AND_CONFIG_MAP"
            }
            roleArnSelector = {
                matchControllerRef = True
                matchLabels = {
                    role = "controlplane"
                }
            }
            vpcConfig = {
                endpointPrivateAccess = True
                subnetIdSelector = {
                    matchLabels = {
                        access = "public"
                        "networks.aws.platform.upbound.io/network-id" = "configuration-aws-eks"
                    }
                }
            }
        }
        providerConfigRef = {
            name = "default"
        }
    }
}

_xr = platformawsv1alpha1.XEKS {
    metadata = {
        name = "configuration-aws-eks"
    }
    spec = {
        parameters = {
            id = "configuration-aws-eks"
            nodes = {
                count = 1
                instanceType = "t3.small"
            }
            region = "us-west-2"
        }
        writeConnectionSecretToRef = {
            name = "configuration-aws-eks-kubeconfig"
            namespace = "upbound-system"
        }
    }
}

_roleControlPlane = iamv1beta1.Role {
    metadata = {
        annotations = {
            "crossplane.io/composition-resource-name" = "controlplaneRole"
        }
        generateName = "configuration-aws-eks-"
        labels = {
            "crossplane.io/composite" = "configuration-aws-eks"
            role = "controlplane"
        }
    }
    spec = {
        deletionPolicy = "Delete"
        forProvider = {
            assumeRolePolicy = r"""{
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
            forceDetachPolicies = True
            managedPolicyArns = [
                "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
            ]
        }
        providerConfigRef = {
            name = "default"
        }
    }
}

_roleNodeGroup = iamv1beta1.Role {
    metadata = {
        annotations = {
            "crossplane.io/composition-resource-name" = "nodegroupRole"
        }
        generateName = "configuration-aws-eks-"
        labels = {
            "crossplane.io/composite" = "configuration-aws-eks"
            role = "nodegroup"
        }
    }
    spec = {
        deletionPolicy = "Delete"
        forProvider = {
            assumeRolePolicy = r"""{
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
            forceDetachPolicies = True
            managedPolicyArns = [
                "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
                "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
                "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
                "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
            ]
        }
        providerConfigRef = {
            name = "default"
        }
    }
}
_providerConfigHelm = helmv1alpha1.ProviderConfig {
    metadata = {
        annotations = {
            "crossplane.io/composition-resource-name" = "providerConfig-helm"
        }
        generateName = "configuration-aws-eks-"
        labels = {
            "crossplane.io/composite" = "configuration-aws-eks"
        }
        name = "configuration-aws-eks"
    }
    spec = {
        credentials = {
            secretRef = {
                key = "kubeconfig"
                name = "-ekscluster"
                namespace = "upbound-system"
            }
            source = "Secret"
        }
    }
}
_providerConfigKubernetes = kubernetesv1alpha1.ProviderConfig {
    metadata = {
        annotations = {
            "crossplane.io/composition-resource-name" = "providerConfig-kubernetes"
        }
        generateName = "configuration-aws-eks-"
        labels = {
            "crossplane.io/composite" = "configuration-aws-eks"
        }
        name = "configuration-aws-eks"
    }
    spec = {
        credentials = {
            secretRef = {
                key = "kubeconfig"
                name = "-ekscluster"
                namespace = "upbound-system"
            }
            source = "Secret"
        }
    }
}

_kubernetesClusterAuth = eksv1beta1.ClusterAuth {
    metadata = {
        annotations = {
            "crossplane.io/composition-resource-name" = "kubernetesClusterAuth"
        }
        generateName = "configuration-aws-eks-"
        labels = {
            "crossplane.io/composite" = "configuration-aws-eks"
        }
    }
    spec = {
        deletionPolicy = "Delete"
        forProvider = {
            clusterNameSelector = {
                matchControllerRef = True
            }
            refreshPeriod = "10m0s"
            region = "us-west-2"
        }
        managementPolicies = [
            "*"
        ]
        providerConfigRef = {
            name = "default"
        }
        writeConnectionSecretToRef = {
            name = "-ekscluster"
            namespace = "upbound-system"
        }
    }
}

_vpcCniAddon = eksv1beta1.Addon {
    metadata: {
        annotations: {
            "crossplane.io/composition-resource-name": "vpc-cni-addon"
        }
        generateName = "configuration-aws-eks-"
        labels = {
            "crossplane.io/composite" = "configuration-aws-eks"
        }
    }
    spec: {
        deletionPolicy: "Delete"
        forProvider = {
            addonName: "vpc-cni"
            clusterNameSelector: {
                matchControllerRef: True
            }
            region: "us-west-2"
            configurationValues: '{"env": {"AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG":"false"}}'
        }
        managementPolicies = [
            "*"
        ]
        providerConfigRef = {
            name = "default"
        }
    }
}

_nodeGroupPublic = eksv1beta2.NodeGroup {
    metadata: {
        annotations: {
            "crossplane.io/composition-resource-name": "nodeGroupPublic"
        }
        generateName = "configuration-aws-eks-"
        labels = {
            "crossplane.io/composite" = "configuration-aws-eks"
        }
    }
    spec: {
        deletionPolicy: "Delete"
        forProvider = {
            region = "us-west-2"
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
            instanceTypes = ["t3.small"]
            subnetIdSelector.matchLabels = {
                "networks.aws.platform.upbound.io/network-id" = "configuration-aws-eks"
                access = "public"
            }
        }
        initProvider = {
            scalingConfig = {
                desiredSize = 1
            }
        }
        managementPolicies = [
            "*"
        ]
        providerConfigRef = {
            name = "default"
        }
    }
}

_awsEbsCsiDriverAddon = eksv1beta1.Addon {
    metadata: {
        annotations: {
            "crossplane.io/composition-resource-name": "aws-ebs-csi-driver-addon"
        }
        generateName = "configuration-aws-eks-"
        labels = {
            "crossplane.io/composite" = "configuration-aws-eks"
        }
    }
    spec: {
        deletionPolicy: "Delete"
        forProvider = {
            addonName: "aws-ebs-csi-driver"
            clusterNameSelector: {
                matchControllerRef: True
            }
            region: "us-west-2"
        }
        managementPolicies = [
            "*"
        ]
        providerConfigRef = {
            name = "default"
        }
    }
}

_eksPodIdentityAgentAddon = eksv1beta1.Addon {
    metadata: {
        annotations: {
            "crossplane.io/composition-resource-name": "eks-pod-identity-agent-addon"
        }
        generateName = "configuration-aws-eks-"
        labels = {
            "crossplane.io/composite" = "configuration-aws-eks"
        }
    }
    spec: {
        deletionPolicy: "Delete"
        forProvider = {
            addonName: "eks-pod-identity-agent"
            clusterNameSelector: {
                matchControllerRef: True
            }
            region: "us-west-2"
        }
        managementPolicies = [
            "*"
        ]
        providerConfigRef = {
            name = "default"
        }
    }
}
