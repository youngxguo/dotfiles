import {
  CustomEditor,
  type ExtensionAPI,
  type KeybindingsManager,
  type Theme,
} from "@earendil-works/pi-coding-agent";
import {
  stripTerminalSequences,
  type EditorTheme,
  type TUI,
} from "@earendil-works/pi-tui";

/** Keep the panel background active across the editor's fake-cursor resets. */
function addBackground(line: string, theme: Theme): string {
  const background = theme.getBgAnsi("userMessageBg");
  const content = line
    .replaceAll("\x1b[0m", `\x1b[0m${background}`)
    .replaceAll("\x1b[49m", `\x1b[49m${background}`);
  return `${background}${content}\x1b[49m`;
}

class PiEditor extends CustomEditor {
  constructor(
    tui: TUI,
    editorTheme: EditorTheme,
    keybindings: KeybindingsManager,
    private readonly panelTheme: Theme,
    private readonly panelPaddingX = 1,
    private readonly panelPaddingY = 1,
    private readonly marginBottom = 1,
  ) {
    super(tui, editorTheme, keybindings, { paddingX: panelPaddingX });
  }

  override setPaddingX(): void {
    super.setPaddingX(this.panelPaddingX);
  }

  override render(width: number): string[] {
    const lines = super.render(width);
    let bottomBorder = lines.length - 1;
    for (let index = lines.length - 1; index > 0; index--) {
      const plain = stripTerminalSequences(lines[index]!);
      if (/^─+$/.test(plain) || plain.startsWith("─── ↓ ")) {
        bottomBorder = index;
        break;
      }
    }

    const padding = Array.from({ length: this.panelPaddingY }, () =>
      " ".repeat(width),
    );
    const content = lines.slice(1, bottomBorder);
    const autocomplete = lines.slice(bottomBorder + 1);
    const panel = [...padding, ...content, ...padding, ...autocomplete].map(
      (line) => addBackground(line, this.panelTheme),
    );
    return [...panel, ...Array.from({ length: this.marginBottom }, () => "")];
  }
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    ctx.ui.setEditorComponent(
      (tui, editorTheme, keybindings) =>
        new PiEditor(tui, editorTheme, keybindings, ctx.ui.theme),
    );
  });
}
