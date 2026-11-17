import 'dart:async';

import 'package:flutter/widgets.dart';

import '../ide/ide_menu.dart';
import '../kernel/antigravity/antigravity_cli.dart';
import '../l10n/l10n.dart';
import 'model_provider.dart';
import 'model_providers.dart';

const _agyFlashRef = '@$antigravityBuiltinProviderId/gemini-3.8-flash';
const _agyFlashLegacyRef =
    '@$antigravityBuiltinProviderId/gemini-3.8-flash-low';

/// The choices of an auxiliary model, as Settings → Models gives them:
/// [autoLabel] first (automatic: [auto]), Antigravity CLI Flash when offered,
/// then each custom provider's models; [current] checked.
List<IdeMenuEntry> auxiliaryModelEntries(
  AppLocalizations l10n,
  ModelProviders providers, {
  required String? current,
  required ValueChanged<String?> onPick,
  String? auto,
  String? autoLabel,
}) => [
  IdeMenuAction(
    autoLabel ?? l10n.modelsAuxiliaryAuto,
    checked:
        current == auto ||
        (current == builtinProviderId && !providers.builtinAvailable),
    onSelected: () => onPick(auto),
  ),
  const IdeMenuSeparator(),
  if (providers.antigravityOffered)
    IdeMenuAction(
      'Antigravity CLI · Gemini 3.8 Flash',
      checked: current == _agyFlashRef || current == _agyFlashLegacyRef,
      onSelected: () => onPick(_agyFlashRef),
    ),
  for (final provider in providers.enabled)
    IdeMenuAction(
      provider.name,
      checked: parseModelRef(current)?.provider == provider.id,
      submenu: [
        for (final model in provider.enabledModels)
          IdeMenuAction(
            provider.labelOf(model),
            checked: current == modelRef(provider.id, model.id),
            onSelected: () => onPick(modelRef(provider.id, model.id)),
          ),
      ],
    ),
];

/// [ModelProviders.actionsModel] by name, as its menu shows it; null while
/// none is picked.
String? actionsModelName(AppLocalizations l10n, ModelProviders providers) {
  final value = providers.actionsModel;
  return switch (value) {
    null => null,
    ModelProviders.followAuxiliary => l10n.aiModelAuxiliary,
    _agyFlashRef || _agyFlashLegacyRef =>
      'Antigravity CLI · Gemini 3.8 Flash',
    builtinProviderId => l10n.aiModelAuxiliary,
    _ => switch (providers.resolve(value)) {
      (final provider, final model) =>
        '${provider.name} · ${provider.labelOf(model)}',
      null => value,
    },
  };
}

/// Shows the menu that picks the model of the AI actions
/// ([ModelProviders.actionsModel], one for them all) at [anchor]; it says
/// so first while none is picked. Whether one is picked once it closes.
Future<bool> pickActionsModel(BuildContext context, Rect anchor) async {
  final l10n = context.l10n;
  final providers = ModelProviders.current;
  final current = providers.actionsModel;
  Future<void>? picked;
  await showIdeMenu(
    context,
    anchor: anchor,
    entries: [
      if (current == null) ...[
        IdeMenuAction(l10n.aiModelFirst, enabled: false),
        const IdeMenuSeparator(),
      ],
      ...auxiliaryModelEntries(
        l10n,
        providers,
        current: current,
        auto: ModelProviders.followAuxiliary,
        autoLabel: l10n.aiModelAuxiliary,
        onPick: (model) => picked = providers.setActionsModel(model),
      ),
    ],
  );
  if (picked case final picking?) await picking;
  return providers.actionsModel != null;
}

/// Runs [action], an AI action, with its model: at once where one is
/// picked, else once one is in the menu at [anchor] ([pickActionsModel]);
/// not at all where none is.
Future<void> withActionsModel(
  BuildContext context,
  Rect anchor,
  FutureOr<void> Function() action,
) async {
  if (ModelProviders.current.actionsModel == null &&
      !await pickActionsModel(context, anchor)) {
    return;
  }
  await action();
}

/// Where [context]'s widget is, globally: what a menu for it opens by.
Rect? anchorOf(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
