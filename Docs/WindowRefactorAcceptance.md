# Aceitação da descoberta, alternância e transparência

Este relatório acompanha a refatoração posterior à versão 1.1.0. Ele separa
resultados reproduzíveis, validações guiadas e verificações que dependem de um
aplicativo ou hardware indisponível no ambiente de desenvolvimento.

## Estado

| Verificação | Estado | Evidência esperada |
|---|---|---|
| Fixtures de descoberta, identidade e ativação | **Aprovada** | 57 `TaberTests` em `Build/Validation/20260908-182335.xcresult` |
| Event tap, Command-up perdido e overlays | **Aprovada por fixture/UI** | `TaberTests` e `TaberUITests` |
| Transparência ON/OFF, temas e visuais | **Aprovada por fixture e inspeção representativa** | 198 imagens em `/tmp/taber-task4-visuals-final` |
| Build universal sem assinatura | **Aprovada** | arm64 + x86_64, `CODE_SIGNING_ALLOWED=NO` |
| League-like | **Aprovada por fixture** | renderer aninhado, CG-only e fallback por app |
| League of Legends instalado | **Aguardando validação guiada** | checklist e logs locais abaixo |

Uma fixture aprovada confirma a regra de decisão, mas não é uma aprovação ponta
a ponta do aplicativo real. O League não está instalado no Mac de
desenvolvimento e, portanto, cliente, partida e fullscreen real permanecem com
o estado **aguardando validação guiada**.

Execução final em 08/09/2026, macOS 26.6.2 arm64: 20 regressões puras,
4 fixtures da sonda, 57 testes lógicos e 1 teste de UI aprovados, sem falhas.
O teste HID opcional permaneceu fora da suíte por exigir janelas descartáveis e
teclado físico. O gate de 200 janelas mediu mediana de **1,519 ms**, abaixo da
baseline 1.1.0 de 5,568 ms e do limite de 6,125 ms (+10%).

A validação de 57 testes acrescenta dois casos de regressão: sair de uma
superfície fullscreen/CG-only sem AX confiável para outra aplicação e repetir
o foco da mesma identidade depois que o macOS inicia a mudança de Space.

## Sonda de elegibilidade

A sonda usa a mesma `WindowEligibilityPolicy.evaluate` do produto e imprime o
motivo tipado de cada decisão. Ela lê apenas o snapshot do WindowServer; o Taber
também consulta AX durante a descoberta. Por isso, `activationFallback` é uma
previsão conservadora e não substitui o log da estratégia realmente executada.

Compile uma vez:

```bash
testDir="$(mktemp -d /tmp/taber-window-check.XXXXXX)"
xcrun swiftc \
  -module-cache-path "$testDir/cache" \
  Sources/Taber/Services/WindowEligibilityPolicy.swift \
  Scripts/WindowEligibilityCheck/main.swift \
  -o "$testDir/taber-window-check"
```

Com o cliente ou a partida abertos, filtre os processos relacionados:

```bash
"$testDir/taber-window-check" --bundle league
"$testDir/taber-window-check" --bundle riot
```

Os títulos ficam ocultos por padrão. `--show-titles` deve ser usado somente
quando o operador tiver revisado o conteúdo que será exibido. Outras opções:

- `--eligible-only`: mostra apenas superfícies aceitas;
- `--exclude-utilities`: reproduz a preferência de auxiliares desligada;
- `--self-test`: valida fixtures da política sem consultar o WindowServer;
- `--help`: lista as opções disponíveis.

Interpretação dos motivos:

| Motivo | Decisão |
|---|---|
| `standardWindow`, `dialog`, `utility` | janela AX legítima; utility depende da preferência |
| `customSurface` | superfície CG de usuário sem AX suficiente |
| `nestedRenderer` | superfície legítima pertencente a renderer/helper aninhado |
| `systemShell` | componente interno conhecido do macOS |
| `noUserSurface` | evidência insuficiente de uma janela de usuário |
| `utilityDisabled` | auxiliar real, mas opção de inclusão desligada |
| `implausibleGeometry` | geometria incompatível com um alvo do alternador |

Uma superfície esperada do League deve aparecer como `INCLUI`, normalmente com
`customSurface` ou `nestedRenderer` quando a árvore AX estiver incompleta. Uma
linha `EXCLUI` deve ser anexada ao relato sem habilitar `--show-titles`, salvo se
o título for indispensável ao diagnóstico.

## Log da estratégia efetiva

Em outro Terminal, observe somente as categorias do Taber:

```bash
log stream --style compact --level info \
  --predicate 'subsystem == "com.taber.app" && (category == "activation" || category == "windows")'
```

Depois selecione a janela no Taber. A linha de ativação registra PID dono, PID
ativado, estratégia, resultado e etapas, sem registrar título. Estratégias
válidas:

- `accessibilityWindow`: restaura/foca/eleva uma janela AX identificada;
- `application`: fallback controlado para um alvo CG-only não ambíguo;
- `localWindow`: ativação AppKit da janela de Configurações do Taber.

Para League com AX incompleto, `application` é o resultado esperado. Se AX
identificar a janela de forma única, `accessibilityWindow` também é válido. O
resultado só é aprovado quando o foco retorna para a superfície escolhida e o
log termina em `activated`; presença na lista, isoladamente, não basta.

## Checklist guiado — League of Legends

Antes de começar, registre data, versão do macOS, versão do League/Riot Client,
modelo de tela, quantidade de monitores e Space usado. Confirme que o Taber tem
permissão de Acessibilidade. Gravação de Tela é necessária para miniaturas, mas
uma miniatura vazia não deve bloquear a alternância.

Para cada linha, mantenha outra janela de referência aberta para alternar de e
para o League. Repita ao menos três vezes, incluindo um retorno após minimizar
ou trocar de Space quando o modo permitir.

| Cenário real | Presente no Taber | Foco retorna | Estratégia/result | Miniatura não bloqueia | Estado |
|---|---|---|---|---|---|
| Cliente em janela | ☐ | ☐ | __________ | ☐ | Aguardando |
| Cliente em fullscreen, se suportado | ☐ | ☐ | __________ | ☐ | Aguardando |
| Partida de treino em janela/sem borda | ☐ | ☐ | __________ | ☐ | Aguardando |
| Partida de treino em fullscreen | ☐ | ☐ | __________ | ☐ | Aguardando |

Em cada cenário:

1. Execute as sondas `--bundle league` e `--bundle riot` e guarde somente as
   linhas relevantes e o `SUMMARY`.
2. Abra o Taber e confirme uma entrada correspondente à superfície do usuário,
   sem listar agentes ou processos headless do Riot Client.
3. Escolha outra janela, volte ao League e confirme visualmente que teclado e
   mouse foram direcionados à superfície esperada.
4. Registre `strategy`, `result` e `steps` da linha de ativação.
5. Repita com a superfície minimizada, em outro Space e com miniatura
   indisponível quando esses estados forem suportados.
6. Reprove o cenário se o Taber ativar outra janela do mesmo app, listar uma
   superfície técnica, deixar overlay sobreposto ou depender da miniatura.

Não use uma partida ranqueada para validação. Se o jogo impedir captura ou
automação, registre a limitação; não converta ausência de evidência em aprovação.

## Checklist geral de interface

- A janela Configurações aparece no ciclo enquanto aberta ou minimizada e é
  ativada com estratégia `localWindow`.
- Switcher, painel rápido, preview e menu nativo nunca aparecem como alvos.
- Somente um overlay do Taber permanece visível; Esc, clique externo, abertura
  das Configurações, início de `Command + Tab` e troca de app fecham o painel
  rápido conforme o contexto.
- A perda de Command-up e a desativação do event tap encerram o ciclo sem deixar
  o painel acima de outras janelas.
- Transparência desligada usa fundo sólido. Ligada, aparece nos quatro visuais,
  painel rápido e Configurações em Original, Dark e Claro.
- “Reduzir Transparência” do macOS força fundo sólido sem apagar a preferência
  salva do Taber.

## Privacidade da evidência

`.xcresult`, imagens da área de trabalho e logs permanecem locais. A sonda
redige títulos por padrão, mas ainda mostra nomes de aplicativos, bundles, PIDs,
IDs de janela e geometrias. Revise esse material antes de compartilhá-lo.
