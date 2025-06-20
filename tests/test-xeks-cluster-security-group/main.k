import models.io.upbound.aws.eks.v1beta2 as eksv1beta2
import models.io.upbound.aws.ec2.v1beta1 as ec2v1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1

_items = [
    metav1alpha1.CompositionTest{
        metadata.name: "test-xeks-cluster-security-group"
        spec= {
            assertResources: [
                platformawsv1alpha1.XEKS{
                    metadata.name: "configuration-aws-eks"
                    spec: {
                        parameters: {
                            id: "configuration-aws-eks"
                            region: "us-west-2"
                            nodes: {
                                count: 1
                                instanceType: "t3.small"
                            }
                            accessConfig: {
                                authenticationMode: "API_AND_CONFIG_MAP"
                                bootstrapClusterCreatorAdminPermissions: True
                            }
                            iam: {
                                principalArn: "arn:12345678910-test"
                            }
                        }
                        writeConnectionSecretToRef: {
                            name: "configuration-aws-eks-kubeconfig"
                            namespace: "upbound-system"
                        }
                    }
                }
                ec2v1beta1.SecurityGroup{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "clusterSecurityGroupImport"
                            "crossplane.io/external-name" = "sg-12345678910"
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
                            tags: {
                                "eks.aws.platform.upbound.io/discovery" = "configuration-aws-eks"
                            }
                        }
                        providerConfigRef = {
                            name = "default"
                        }
                    }

                }
            ]
            observedResources: [
                eksv1beta2.Cluster{
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
                    status: {
                        atProvider: {
                            vpcConfig: {
                                clusterSecurityGroupId: "sg-12345678910"
                            }
                        }
                    }
                }
            ]
            compositionPath: "apis/composition.yaml"
            xr: platformawsv1alpha1.XEKS{
                metadata.name: "configuration-aws-eks"
                spec: {
                    parameters: {
                        id: "configuration-aws-eks"
                        region: "us-west-2"
                        nodes: {
                            count: 1
                            instanceType: "t3.small"
                        }
                        accessConfig: {
                            authenticationMode: "API_AND_CONFIG_MAP"
                            bootstrapClusterCreatorAdminPermissions: True
                        }
                        iam: {
                            principalArn: "arn:12345678910-test"
                        }
                    }
                    writeConnectionSecretToRef: {
                        name: "configuration-aws-eks-kubeconfig"
                        namespace: "upbound-system"
                    }
                }
            }
            xrdPath: "apis/definition.yaml"
            timeoutSeconds: 60
            validate: False
        }
    }
]
items= _items
