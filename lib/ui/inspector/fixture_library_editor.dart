/// The user-defined fixture library editor — a custom design-system modal to
/// create / edit / delete [CustomFixture] types (name + supply UBAP + drainage
/// DFU + default mounting height + flush-valve toggle).
///
/// No Material: a [showGeneralDialog]-driven floating card, themed with
/// [MechXTheme], over the [fixtureLibraryProvider] store. Every on-card text
/// style comes from `context.type` (Roboto-backed) so it renders in goldens.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/standards/custom_fixture.dart';
import 'package:mechx_engine/units.dart';

import '../../store/fixture_library_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import '../widgets/mechx_text_field.dart';

/// Open the fixture-library editor as a modal over the current [MechXTheme].
Future<void> showFixtureLibraryEditor(BuildContext context, WidgetRef ref) {
  final theme = MechXTheme.of(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fixture library',
    barrierColor: const Color(0x66000000),
    pageBuilder: (ctx, _, _) => MechXTheme(
      data: theme,
      child: const Center(child: _FixtureLibraryDialog()),
    ),
  );
}

class _FixtureLibraryDialog extends ConsumerStatefulWidget {
  const _FixtureLibraryDialog();

  @override
  ConsumerState<_FixtureLibraryDialog> createState() =>
      _FixtureLibraryDialogState();
}

class _FixtureLibraryDialogState extends ConsumerState<_FixtureLibraryDialog> {
  /// Id of the fixture being edited, or null when adding a new one.
  String? _editingId;
  String _name = '';
  double _supplyUnits = 1;
  double _drainageUnits = 1;
  double? _mountingHeightM;
  bool _isFlushValve = false;

  int _seq = 0;

  void _startNew() {
    setState(() {
      _editingId = null;
      _name = '';
      _supplyUnits = 1;
      _drainageUnits = 1;
      _mountingHeightM = null;
      _isFlushValve = false;
    });
  }

  void _startEdit(CustomFixture f) {
    setState(() {
      _editingId = f.id;
      _name = f.name;
      _supplyUnits = f.supplyUnits;
      _drainageUnits = f.drainageUnits;
      _mountingHeightM = f.defaultMountingHeight?.meters;
      _isFlushValve = f.isFlushValve;
    });
  }

  void _save() {
    final ctrl = ref.read(fixtureLibraryProvider.notifier);
    final name = _name.trim().isEmpty ? 'Custom fixture' : _name.trim();
    final id = _editingId ??
        'cf${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
    final fixture = CustomFixture(
      id: id,
      name: name,
      supplyUnits: _supplyUnits,
      drainageUnits: _drainageUnits,
      defaultMountingHeight:
          _mountingHeightM == null ? null : Length(_mountingHeightM!),
      isFlushValve: _isFlushValve,
    );
    if (_editingId == null) {
      ctrl.add(fixture);
    } else {
      ctrl.update(fixture);
    }
    _startNew();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final library = ref.watch(fixtureLibraryProvider);

    return Container(
      width: 460,
      constraints: const BoxConstraints(maxHeight: 640),
      padding: const EdgeInsets.all(MechXSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: MechXRadii.card,
        boxShadow: MechXShadow.popover,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Fixture library',
                    style: type.title.copyWith(color: colors.textPrimary)),
              ),
              MechXButton(
                label: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.xs),
          Text(
            'Define custom fixtures with their UBAP supply + DFU drainage loads. '
            'Assign them to nodes from the Selection inspector.',
            style: type.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: MechXSpacing.md),
          // Existing entries.
          if (library.isEmpty)
            Text('No custom fixtures yet.',
                style: type.body.copyWith(color: colors.textSecondary))
          else
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final f in library)
                      _FixtureRow(
                        fixture: f,
                        editing: f.id == _editingId,
                        onEdit: () => _startEdit(f),
                        onDelete: () {
                          ref
                              .read(fixtureLibraryProvider.notifier)
                              .remove(f.id);
                          if (_editingId == f.id) _startNew();
                        },
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: MechXSpacing.md),
          Container(height: 1, color: colors.border),
          const SizedBox(height: MechXSpacing.md),
          Text(_editingId == null ? 'New fixture' : 'Edit fixture',
              style: type.subtitle.copyWith(color: colors.textPrimary)),
          const SizedBox(height: MechXSpacing.sm),
          _Field(
            label: 'Name',
            child: MechXTextField(
              value: _name,
              onChanged: (v) => setState(() => _name = v),
            ),
          ),
          const SizedBox(height: MechXSpacing.sm),
          _Stepper(
            label: 'Supply UBAP',
            value: _supplyUnits,
            suffix: '',
            onChanged: (v) => setState(() => _supplyUnits = v),
          ),
          const SizedBox(height: MechXSpacing.sm),
          _Stepper(
            label: 'Drainage DFU',
            value: _drainageUnits,
            suffix: '',
            onChanged: (v) => setState(() => _drainageUnits = v),
          ),
          const SizedBox(height: MechXSpacing.sm),
          _Stepper(
            label: 'Mounting height',
            value: _mountingHeightM ?? 0,
            suffix: ' m',
            step: 0.1,
            allowNull: true,
            isNull: _mountingHeightM == null,
            onChanged: (v) => setState(() => _mountingHeightM = v),
            onNull: () => setState(() => _mountingHeightM = null),
          ),
          const SizedBox(height: MechXSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text('Flush-valve WC',
                    style: type.body.copyWith(color: colors.textSecondary)),
              ),
              MechXButton(
                label: _isFlushValve ? 'Yes' : 'No',
                primary: _isFlushValve,
                onPressed: () =>
                    setState(() => _isFlushValve = !_isFlushValve),
              ),
            ],
          ),
          const SizedBox(height: MechXSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_editingId != null) ...[
                MechXButton(label: 'Cancel edit', onPressed: _startNew),
                const SizedBox(width: MechXSpacing.sm),
              ],
              MechXButton(
                label: _editingId == null ? 'Add fixture' : 'Save changes',
                primary: true,
                onPressed: _save,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FixtureRow extends StatelessWidget {
  final CustomFixture fixture;
  final bool editing;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _FixtureRow({
    required this.fixture,
    required this.editing,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final mh = fixture.defaultMountingHeight;
    return Container(
      margin: const EdgeInsets.only(bottom: MechXSpacing.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: MechXSpacing.sm,
        vertical: MechXSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: editing ? colors.accentMuted : colors.background,
        borderRadius: MechXRadii.control,
        border: Border.all(color: editing ? colors.accent : colors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fixture.name,
                    style:
                        type.body.copyWith(color: colors.textPrimary)),
                Text(
                  'UBAP ${_fmt(fixture.supplyUnits)} · DFU '
                  '${_fmt(fixture.drainageUnits)}'
                  '${mh == null ? '' : ' · ${mh.meters.toStringAsFixed(2)} m'}'
                  '${fixture.isFlushValve ? ' · flush valve' : ''}',
                  style: type.caption.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
          MechXButton(label: 'Edit', onPressed: onEdit),
          const SizedBox(width: MechXSpacing.xs),
          MechXButton(label: 'Delete', onPressed: onDelete),
        ],
      ),
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: type.caption.copyWith(color: colors.textMuted)),
        const SizedBox(height: MechXSpacing.xxs),
        child,
      ],
    );
  }
}

/// A small −/value/+ numeric stepper (no Material), optionally clearable.
class _Stepper extends StatelessWidget {
  final String label;
  final double value;
  final String suffix;
  final double step;
  final ValueChanged<double> onChanged;
  final bool allowNull;
  final bool isNull;
  final VoidCallback? onNull;

  const _Stepper({
    required this.label,
    required this.value,
    required this.suffix,
    required this.onChanged,
    this.step = 1,
    this.allowNull = false,
    this.isNull = false,
    this.onNull,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: type.body.copyWith(color: colors.textSecondary)),
        ),
        _Glyph(
          glyph: '−',
          onTap: () {
            final next = (value - step);
            onChanged(next < 0 ? 0 : double.parse(next.toStringAsFixed(2)));
          },
        ),
        const SizedBox(width: MechXSpacing.sm),
        SizedBox(
          width: 64,
          child: Text(
            isNull
                ? '—'
                : '${_fmt(value)}$suffix',
            textAlign: TextAlign.center,
            style: type.mono.copyWith(color: colors.textPrimary),
          ),
        ),
        const SizedBox(width: MechXSpacing.sm),
        _Glyph(
          glyph: '+',
          onTap: () =>
              onChanged(double.parse((value + step).toStringAsFixed(2))),
        ),
        if (allowNull) ...[
          const SizedBox(width: MechXSpacing.sm),
          _Glyph(glyph: '×', onTap: onNull ?? () {}),
        ],
      ],
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}

class _Glyph extends StatelessWidget {
  final String glyph;
  final VoidCallback onTap;
  const _Glyph({required this.glyph, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.surfaceHover,
            borderRadius: MechXRadii.control,
          ),
          child: Text(glyph,
              style: type.body.copyWith(color: colors.textPrimary)),
        ),
      ),
    );
  }
}
