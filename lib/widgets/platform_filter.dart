import 'package:flutter/material.dart';

import '../core/mgba_bindings.dart';
import '../utils/theme.dart';
import 'tv_focusable.dart';

/// Platform filter chips for game library
class PlatformFilter extends StatelessWidget {
  final GamePlatform? selectedPlatform;
  final void Function(GamePlatform?) onChanged;

  const PlatformFilter({
    super.key,
    required this.selectedPlatform,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _FilterChip(
            label: 'All',
            isSelected: selectedPlatform == null,
            color: colors.primary,
            onTap: () => onChanged(null),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'GBA',
            isSelected: selectedPlatform == GamePlatform.gba,
            color: colors.gbaColor,
            onTap: () => onChanged(GamePlatform.gba),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'GBC',
            isSelected: selectedPlatform == GamePlatform.gbc,
            color: colors.gbcColor,
            onTap: () => onChanged(GamePlatform.gbc),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'GB',
            isSelected: selectedPlatform == GamePlatform.gb,
            color: colors.gbColor,
            onTap: () => onChanged(GamePlatform.gb),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'NES',
            isSelected: selectedPlatform == GamePlatform.nes,
            color: colors.nesColor,
            onTap: () => onChanged(GamePlatform.nes),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'SNES',
            isSelected: selectedPlatform == GamePlatform.snes,
            color: colors.snesColor,
            onTap: () => onChanged(GamePlatform.snes),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'MD',
            isSelected: selectedPlatform == GamePlatform.md,
            color: colors.mdColor,
            onTap: () => onChanged(GamePlatform.md),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'SMS',
            isSelected: selectedPlatform == GamePlatform.sms,
            color: colors.smsColor,
            onTap: () => onChanged(GamePlatform.sms),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'GG',
            isSelected: selectedPlatform == GamePlatform.gg,
            color: colors.ggColor,
            onTap: () => onChanged(GamePlatform.gg),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'SG-1000',
            isSelected: selectedPlatform == GamePlatform.sg1000,
            color: colors.smsColor,
            onTap: () => onChanged(GamePlatform.sg1000),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'PCE',
            isSelected: selectedPlatform == GamePlatform.pce,
            color: colors.mdColor,
            onTap: () => onChanged(GamePlatform.pce),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'SGX',
            isSelected: selectedPlatform == GamePlatform.sgx,
            color: colors.mdColor,
            onTap: () => onChanged(GamePlatform.sgx),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'NGP',
            isSelected: selectedPlatform == GamePlatform.ngp,
            color: colors.ngpColor,
            onTap: () => onChanged(GamePlatform.ngp),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'WS',
            isSelected: selectedPlatform == GamePlatform.ws,
            color: colors.wsColor,
            onTap: () => onChanged(GamePlatform.ws),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'WSC',
            isSelected: selectedPlatform == GamePlatform.wsc,
            color: colors.wscColor,
            onTap: () => onChanged(GamePlatform.wsc),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'A2600',
            isSelected: selectedPlatform == GamePlatform.a2600,
            color: colors.a2600Color,
            onTap: () => onChanged(GamePlatform.a2600),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'VB',
            isSelected: selectedPlatform == GamePlatform.vb,
            color: colors.vbColor,
            onTap: () => onChanged(GamePlatform.vb),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'TIC-80',
            isSelected: selectedPlatform == GamePlatform.tic80,
            color: colors.tic80Color,
            onTap: () => onChanged(GamePlatform.tic80),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'PICO-8',
            isSelected: selectedPlatform == GamePlatform.pico8,
            color: colors.pico8Color,
            onTap: () => onChanged(GamePlatform.pico8),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final Color color;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.isSelected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return TvFocusable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? color : colors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? color : colors.surfaceLight,
                  width: 2,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: color.withAlpha(102),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isSelected
                      ? colors.backgroundDark
                      : colors.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
