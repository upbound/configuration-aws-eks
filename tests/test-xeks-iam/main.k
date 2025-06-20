import models.io.upbound.aws.eks.v1beta1 as eksv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1

_items = [
    metav1alpha1.CompositionTest{
        metadata.name: "xeks-iam"
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
                eksv1beta1.AccessEntry{
                    metadata: {
                        annotations: {
                            "crossplane.io/composition-resource-name": "1a0d979a32b0482f0df23e1b0bbf7d1ffdf64fabbbf6d912bc958fbc2a9c937b"
                        }
                        generateName = "configuration-aws-eks-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-eks"
                        }
                    }
                    spec: {
                        deletionPolicy: "Delete"
                        forProvider = {
                            clusterNameSelector: {
                                matchControllerRef: True
                            }
                            region: "us-west-2"
                            type: "STANDARD"
                            principalArn: "arn:12345678910-test"
                        }
                        managementPolicies = [
                            "*"
                        ]
                        providerConfigRef = {
                            name = "default"
                        }
                    }
                }
                eksv1beta1.AccessPolicyAssociation{
                    metadata: {
                        annotations: {
                            "crossplane.io/composition-resource-name": "39cd6d1ddf3182be30e9af47a93a461fd00b1d0682f933123334e54cd5456f7b"
                        }
                        generateName = "configuration-aws-eks-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-eks"
                        }
                    }
                    spec: {
                        deletionPolicy: "Delete"
                        forProvider = {
                            clusterNameSelector: {
                                matchControllerRef: True
                            }
                            region: "us-west-2"
                            accessScope: {
                                type: "cluster"
                            }
                            policyArn: "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
                            principalArnSelector = {
                                matchControllerRef = True
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
