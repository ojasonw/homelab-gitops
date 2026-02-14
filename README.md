# Homelab GitOps

## Visão Geral
Este repositório gerencia a infraestrutura e as aplicações para um cluster Kubernetes de homelab usando princípios de GitOps. Ele utiliza ArgoCD para implantação contínua, Kustomize para personalização de manifestos Kubernetes e SOPS para gerenciamento seguro de segredos diretamente no repositório Git.

## Tecnologias Utilizadas
-   **Kubernetes:** Plataforma de orquestração de containers.
-   **ArgoCD:** Entrega contínua declarativa de GitOps para Kubernetes.
-   **Kustomize:** Personalização de configurações Kubernetes.
-   **SOPS (Secrets OPerationS):** Criptografa segredos armazenados no Git.
-   **Pilha de Monitoramento:**
    -   **Compatível com Prometheus:** Para monitoramento de séries temporais.
    -   **Grafana:** Para visualização de dados e dashboards.
    -   **Alertmanager:** Para gerenciamento e roteamento de alertas.
    -   **VictoriaMetrics:** Uma solução de monitoramento de alto desempenho, escalável e econômica (alternativa/melhoria ao Prometheus).
-   **Cloudflare Tunnel:** Expõe serviços com segurança à internet sem a necessidade de abrir portas de entrada em seu firewall.
-   **n8n:** Uma poderosa ferramenta de automação de fluxo de trabalho.
-   **Exporters:** Vários exporters Prometheus para coletar métricas de diferentes serviços:
    -   **Node Exporter:** Coleta métricas de nível de host de nós Kubernetes.
    -   **PiHole Exporter:** Exporta métricas de instâncias Pi-Hole.
    -   **PVE Exporter:** Exporta métricas de hosts do Proxmox Virtual Environment.
    -   **Speedtest Exporter:** Executa periodicamente testes de velocidade da internet e expõe os resultados como métricas.

## Estrutura do Repositório

-   `argocd/`: Contém as definições de Aplicação do ArgoCD.
    -   `root-app.yaml`: A Aplicação ArgoCD primária que orquestra a implantação de todas as outras aplicações definidas neste repositório.
    -   `infra/`: Definições individuais de Aplicações ArgoCD para vários componentes de infraestrutura, referenciando bases Kustomize no diretório `infra/`.

-   `infra/`: Armazena os manifestos base do Kubernetes, organizados por aplicação, principalmente usando Kustomize.
    -   Cada subdiretório (por exemplo, `cloudflare-tunnel`, `exporters`, `monitoring`, `n8n`) representa uma aplicação ou pilha distinta, contendo suas definições Kustomize `base/`.
    -   `exporters/`: Contém as bases Kustomize para todos os exporters Prometheus configurados.
    -   `monitoring/`: Contém as bases Kustomize para os componentes da pilha de monitoramento principal (VictoriaMetrics, Grafana, Alertmanager, etc.).

-   `.sops.yaml`: Arquivo de configuração para Mozilla SOPS, definindo a chave de criptografia e as regras para gerenciar segredos criptografados dentro do repositório.

-   `docs/`: Contém documentação suplementar, planos arquitetônicos e outras informações relevantes.

## Primeiros Passos (Visão Geral Conceitual)

Para que esta infraestrutura de homelab seja implantada, você geralmente seguiria estes passos conceituais:

1.  **Pré-requisitos:**
    *   Um cluster Kubernetes funcional.
    *   ArgoCD instalado e configurado em seu cluster.
    *   SOPS instalado localmente e configurado com acesso às chaves de descriptografia (por exemplo, chave GPG ou acesso KMS) que correspondem à configuração `.sops.yaml`.

2.  **Configuração Inicial do ArgoCD:**
    *   Aplique o manifesto `argocd/root-app.yaml` à sua instância ArgoCD. Esta aplicação atua como a "raiz de confiança" e descobrirá e sincronizará automaticamente todas as aplicações filhas definidas em `argocd/infra/`.

3.  **Gerenciamento de Segredos:**
    *   Todos os dados sensíveis são criptografados usando SOPS. Você precisará garantir que seu ambiente local e o ArgoCD (se precisar descriptografar segredos) tenham a configuração SOPS e as chaves necessárias para descriptografar arquivos como `infra/*/base/secret.yaml`.

4.  **Personalização:**
    *   Modifique os diretórios Kustomize `base/` dentro de `infra/` para ajustar configurações, limites de recursos e outras definições para corresponder ao seu ambiente de homelab específico e preferências.

## Aplicações e Serviços Implantados

Este repositório gerencia uma variedade de serviços essenciais de homelab:

-   **Pilha de Monitoramento:** Uma solução de monitoramento abrangente que fornece coleta de métricas, visualização e alertas para seu cluster Kubernetes e serviços integrados.
-   **Cloudflare Tunnel:** Estabelece conexões seguras e somente de saída para a borda da Cloudflare, permitindo que você exponha serviços internos publicamente sem abrir portas em sua rede doméstica.
-   **n8n:** Fornece uma plataforma de automação de fluxo de trabalho auto-hospedada, poderosa e extensível para conectar vários serviços e automatizar tarefas.
-   **Prometheus Exporters:** Coletam e expõem continuamente métricas de diferentes componentes do seu homelab para consumo pela pilha de monitoramento.

## Gerenciamento de Segredos com SOPS

Mozilla SOPS é parte integrante deste repositório para gerenciar informações sensíveis com segurança.
-   Segredos (por exemplo, chaves de API, senhas, configurações sensíveis) são criptografados e armazenados diretamente no repositório Git como arquivos `secret.yaml` dentro do diretório `base/` de cada aplicação.
-   Isso permite o controle de versão transparente de segredos, mantendo-os criptografados em repouso.
-   Certifique-se de que seu ambiente SOPS esteja configurado corretamente para descriptografar esses arquivos durante a implantação. Consulte o arquivo `.sops.yaml` para configurações de chave específicas.
