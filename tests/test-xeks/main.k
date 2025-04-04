
import models.io.crossplane.helm.v1alpha1 as helmv1alpha1
import models.io.crossplane.kubernetes.v1alpha1 as kubernetesv1alpha1
import models.io.upbound.aws.eks.v1beta1 as eksv1beta1
import models.io.upbound.aws.eks.v1beta2 as eksv1beta2
import models.io.upbound.aws.iam.v1beta1 as iamv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1


_items = [
    metav1alpha1.CompositionTest{
        metadata.name: ""
        spec= {
            assertResources: [
                platformawsv1alpha1.XEKS{
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
                            version = "1.27"
                        }
                        writeConnectionSecretToRef = {
                            name = "configuration-aws-eks-kubeconfig"
                            namespace = "upbound-system"
                        }
                    }
                }
                iamv1beta1.Role{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "controlplaneRole"
                        }
                        generateName = "configuration-aws-eks-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-eks"
                            role = "controlplane"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "XEKS"
                                name = "configuration-aws-eks"
                                uid = ""
                            }
                        ]
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
                eksv1beta2.Cluster{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "kubernetesCluster"
                        }
                        generateName = "configuration-aws-eks-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-eks"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "XEKS"
                                name = "configuration-aws-eks"
                                uid = ""
                            }
                        ]
                    }
                    spec = {
                        deletionPolicy = "Delete"
                        forProvider = {
                            region = "us-west-2"
                            roleArnSelector = {
                                matchControllerRef = True
                                matchLabels = {
                                    role = "controlplane"
                                }
                            }
                            version = "1.27"
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
                iamv1beta1.Role{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "nodegroupRole"
                        }
                        generateName = "configuration-aws-eks-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-eks"
                            role = "nodegroup"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "XEKS"
                                name = "configuration-aws-eks"
                                uid = ""
                            }
                        ]
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
                helmv1alpha1.ProviderConfig{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "providerConfig-helm"
                        }
                        generateName = "configuration-aws-eks-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-eks"
                        }
                        name = "configuration-aws-eks"
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "XEKS"
                                name = "configuration-aws-eks"
                                uid = ""
                            }
                        ]
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
                kubernetesv1alpha1.ProviderConfig{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "providerConfig-kubernetes"
                        }
                        generateName = "configuration-aws-eks-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-eks"
                        }
                        name = "configuration-aws-eks"
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "XEKS"
                                name = "configuration-aws-eks"
                                uid = ""
                            }
                        ]
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
                eksv1beta1.ClusterAuth{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "kubeClusterAuth"
                        }
                        generateName = "configuration-aws-eks-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-eks"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "XEKS"
                                name = "configuration-aws-eks"
                                uid = ""
                            }
                        ]
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
            ]
            compositionPath: "apis/composition.yaml"
            xrPath: "examples/eks-xr.yaml"
            xrdPath: "apis/definition.yaml"
            timeoutSeconds: 60
            validate: False
        }
    }
]
items= _items
