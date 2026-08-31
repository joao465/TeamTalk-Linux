# TeamTalk-Linux

Versão Linux separada do projeto **TeamTalk5Pro**.

Este repositório não contém nem modifica `joao465/TeamTalk5Pro`. O workflow clona
o repositório oficial `BearWare/TeamTalk5`, aplica somente uma correção Linux de
hotkeys e gera um pacote Ubuntu 26.04 x86_64.

## O que é corrigido

1. No diálogo Linux, `Ctrl`, `Alt`, `Shift` e `Meta` eram armazenados como máscaras
   (`Qt::CTRL`, etc.), mas a liberação era comparada com `Qt::Key_Control`,
   `Qt::Key_Alt`, etc.
2. O registro X11 de hotkeys em `mainwindow.cpp` estava limitado a Qt menor que 6.
   Ubuntu 26.04 usa Qt 6.
3. Quando o atalho contém somente um modificador, `XGrabKey` precisa receber um
   keycode real. A correção converte `Ctrl` sozinho para `XK_Control_L`.
4. O texto de um modificador sozinho passa a aparecer como `Ctrl`, `Alt`, `Shift`
   ou `Meta`.

## Wayland

A correção de `Ctrl` sozinho como Push-to-Talk **global** é para X11/Xorg.

O mecanismo padrão de atalhos globais do Wayland usa o portal XDG GlobalShortcuts.
A especificação de triggers define um atalho como modificadores mais uma tecla,
portanto `Ctrl` sozinho não é um trigger global portátil no Wayland.

O instalador gráfico detecta a sessão atual e mostra um aviso quando estiver em
Wayland.

## Build

Base oficial BearWare:

`88e85978aa0592eef878bfa1e9d364cb132d6175`

Ao enviar alterações para `main`, o GitHub Actions:

1. clona `BearWare/TeamTalk5`;
2. aplica `patches/apply_linux_hotkeys.py`;
3. compila somente o cliente padrão para Ubuntu 26.04;
4. cria `teamtalk-linux-ctrlptt-ubuntu26-x86_64.tgz`;
5. publica uma GitHub Release com o pacote e os instaladores.

## Instalação gráfica no GNOME

O método recomendado para GNOME é o instalador gráfico em GTK/Zenity.

Baixe `install-gui.sh` da Release mais recente e execute:

```bash
bash install-gui.sh
```

O instalador apresenta uma interface gráfica com:

- **Instalar / Atualizar** — baixa automaticamente a Release mais recente;
- **Abrir TeamTalk** — inicia a instalação existente;
- **Desinstalar** — remove o aplicativo e preserva a configuração;
- barra de progresso durante dependências e download;
- autenticação gráfica do sistema através de PolicyKit quando forem necessárias
  permissões para instalar dependências;
- aviso quando a sessão atual for Wayland;
- opção para abrir o TeamTalk ao concluir.

Os diálogos são componentes GTK padrão do Zenity e podem ser navegados pelo
teclado e por leitores de tela compatíveis com a acessibilidade do GNOME.

Se o Zenity não estiver instalado, o script tenta instalá-lo antes de abrir a
interface.

## Instalação pelo terminal

Também continua disponível o instalador tradicional:

```bash
chmod +x install.sh
./install.sh
```

O instalador não compila no computador do usuário; ele baixa a Release pronta.

Arquivos separados do TeamTalk Pro:

- Aplicativo: `~/.local/opt/teamtalk5-linux-ctrlptt`
- Configuração: `~/.config/teamtalk5-linux-ctrlptt/TeamTalk5.ini`
- Comando: `~/.local/bin/teamtalk5-linux`

## Licença

O TeamTalk5 original é de BearWare.dk. As alterações sobre o cliente seguem os
termos indicados pelo código-fonte upstream.
