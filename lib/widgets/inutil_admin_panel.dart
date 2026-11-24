import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/firebase_auth_service.dart';
import 'inutil_update_gate.dart';

/// Panel integral de Administración de Usuarios y Licencias en Firebase
/// para César (compartido en tiempo real entre InútilTV e Inútil Music).
class InutilAdminPanel extends StatefulWidget {
  const InutilAdminPanel({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (_) => const Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 18),
        child: InutilAdminPanel(),
      ),
    );
  }

  @override
  State<InutilAdminPanel> createState() => _InutilAdminPanelState();
}

class _InutilAdminPanelState extends State<InutilAdminPanel> {
  static const _bgDark = Color(0xFF070709);
  static const _surface = Color(0xFF0C0C0F);
  static const _brandCyan = Color(0xFFF5F7F5);
  static const _brandAmber = Color(0xFFE8B949);

  List<InutilUser> _users = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String _selectedFilter = 'todos'; // todos, pendientes, activos, vencidos, admins

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    final list = await InutilAuthService.instance.getAllUsers();
    if (mounted) {
      setState(() {
        _users = list;
        _isLoading = false;
      });
    }
  }

  void _showSnack(String msg, {Color color = const Color(0xFF181920)}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  List<InutilUser> get _filteredUsers {
    final query = _searchQuery.trim().toLowerCase();
    return _users.where((u) {
      final matchSearch = query.isEmpty ||
          u.email.toLowerCase().contains(query) ||
          u.displayName.toLowerCase().contains(query) ||
          u.uid.toLowerCase().contains(query);
      if (!matchSearch) return false;

      switch (_selectedFilter) {
        case 'pendientes':
          return u.status == 'pending' && !u.isAdmin;
        case 'activos':
          return u.isAdmin || (u.isActive && u.status == 'active' && !u.isExpired);
        case 'vencidos':
          return !u.isAdmin &&
              (u.isExpired || !u.isActive || u.status == 'blocked');
        case 'admins':
          return u.isAdmin;
        default:
          return true;
      }
    }).toList();
  }

  int get _pendingCount =>
      _users.where((u) => u.status == 'pending' && !u.isAdmin).length;

  String _formatDate(DateTime? dt) {
    if (dt == null) return 'Sin fecha';
    if (dt.year >= 2090) return 'Licencia Permanente';
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    return '$d/$m/${dt.year}';
  }

  Future<void> _runAction(Future<void> Function() action, String okMsg,
      {Color okColor = const Color(0xFF181920)}) async {
    try {
      await action();
      await _loadUsers();
      _showSnack(okMsg, color: okColor);
    } catch (e) {
      _showSnack(
        e.toString().replaceAll('Exception: ', ''),
        color: Colors.redAccent,
      );
    }
  }

  Future<void> _grantVigencia(
    String uid,
    int days, {
    bool isPermanent = false,
    required String email,
  }) async {
    final msg = isPermanent
        ? '💎 Licencia Permanente concedida a $email'
        : '+$days días de vigencia otorgados a $email';
    await _runAction(
      () => InutilAuthService.instance.adminGrantVigencia(
        uid: uid,
        additionalDays: days,
        isPermanent: isPermanent,
      ),
      msg,
      okColor: isPermanent ? const Color(0xFF9C6B00) : const Color(0xFF181920),
    );
  }

  Future<void> _pickCustomDate(
    String uid,
    String email,
    DateTime? currentDate,
  ) async {
    final now = DateTime.now();
    final initialDate = (currentDate != null &&
            currentDate.isAfter(now) &&
            currentDate.year < 2090)
        ? currentDate
        : now.add(const Duration(days: 30));

    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: now,
      lastDate: DateTime(2099, 12, 31),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: _brandCyan,
            surface: _surface,
          ),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
    );

    if (picked != null) {
      await _runAction(
        () => InutilAuthService.instance.adminSetExactExpiration(
          uid: uid,
          newExpiry: picked,
        ),
        'Vencimiento de $email fijado al ${_formatDate(picked)}',
      );
    }
  }

  Future<void> _toggleActive(
    String uid,
    bool currentActive,
    String email,
  ) async {
    final nextActive = !currentActive;
    await _runAction(
      () => InutilAuthService.instance.adminToggleUserActive(
        uid: uid,
        isActive: nextActive,
      ),
      'Cuenta de $email: ${nextActive ? "Activada" : "Suspendida"}',
      okColor: nextActive ? Colors.green.shade700 : Colors.orange.shade800,
    );
  }

  Future<void> _toggleRole(
    String uid,
    String currentRole,
    String email,
  ) async {
    final newRole = currentRole == 'admin' ? 'user' : 'admin';
    await _runAction(
      () => InutilAuthService.instance.adminToggleUserRole(
        uid: uid,
        role: newRole,
      ),
      'Rol de $email actualizado a: $newRole',
      okColor: newRole == 'admin' ? Colors.amber.shade800 : Colors.blueGrey,
    );
  }

  Future<void> _releaseDevices(String uid, String email) async {
    await _runAction(
      () => InutilAuthService.instance.adminRevokeDevice(uid),
      'Dispositivos de $email liberados (Music y TV).',
      okColor: const Color(0xFF181920),
    );
  }

  Future<void> _deleteUserConfirm(String uid, String email) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          '¿Eliminar Usuario?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          '¿Estás seguro de eliminar la licencia y perfil en Firestore de $email?',
          style: const TextStyle(color: Colors.white70, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                const Text('Cancelar', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text(
              'Eliminar',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _runAction(
        () => InutilAuthService.instance.adminDeleteUser(uid),
        'Usuario $email eliminado de Firestore.',
        okColor: Colors.redAccent,
      );
    }
  }

  Future<void> _showCreateUserDialog() async {
    final emailCtl = TextEditingController();
    final passwordCtl = TextEditingController();
    final nameCtl = TextEditingController();
    int initialDays = 30;
    bool isPermanent = false;
    bool creating = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: _surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: _brandCyan.withValues(alpha: 0.35)),
          ),
          title: const Row(
            children: [
              Icon(Icons.person_add_rounded, color: _brandCyan),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Registrar Nuevo Usuario',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: emailCtl,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: 'Correo Electrónico',
                    labelStyle: TextStyle(color: Colors.white60),
                    prefixIcon:
                        Icon(Icons.email_outlined, color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passwordCtl,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: 'Contraseña Inicial (mín. 6)',
                    labelStyle: TextStyle(color: Colors.white60),
                    prefixIcon: Icon(
                      Icons.lock_outline_rounded,
                      color: Colors.white54,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtl,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: 'Nombre o Alias',
                    labelStyle: TextStyle(color: Colors.white60),
                    prefixIcon:
                        Icon(Icons.badge_outlined, color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Vigencia Inicial (válida en Inutix TV e Inútil Music):',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('30 Días'),
                      selected: initialDays == 30 && !isPermanent,
                      onSelected: (_) => setDialogState(() {
                        initialDays = 30;
                        isPermanent = false;
                      }),
                    ),
                    ChoiceChip(
                      label: const Text('90 Días'),
                      selected: initialDays == 90 && !isPermanent,
                      onSelected: (_) => setDialogState(() {
                        initialDays = 90;
                        isPermanent = false;
                      }),
                    ),
                    ChoiceChip(
                      label: const Text('1 Año'),
                      selected: initialDays == 365 && !isPermanent,
                      onSelected: (_) => setDialogState(() {
                        initialDays = 365;
                        isPermanent = false;
                      }),
                    ),
                    ChoiceChip(
                      label: const Text('💎 Permanente'),
                      selected: isPermanent,
                      selectedColor: _brandAmber.withValues(alpha: 0.3),
                      onSelected: (_) =>
                          setDialogState(() => isPermanent = true),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: creating ? null : () => Navigator.of(ctx).pop(),
              child: const Text(
                'Cancelar',
                style: TextStyle(color: Colors.white60),
              ),
            ),
            ElevatedButton(
              onPressed: creating
                  ? null
                  : () async {
                      final email = emailCtl.text.trim();
                      final password = passwordCtl.text;
                      final name = nameCtl.text.trim();
                      if (email.isEmpty || password.length < 6) {
                        _showSnack(
                          'Ingresa un correo válido y contraseña de al menos 6 caracteres.',
                          color: Colors.orange,
                        );
                        return;
                      }
                      setDialogState(() => creating = true);
                      try {
                        await InutilAuthService.instance.adminCreateUser(
                          email: email,
                          password: password,
                          displayName: name,
                          initialDays: initialDays,
                          isPermanent: isPermanent,
                        );
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        await _loadUsers();
                        _showSnack(
                          'Usuario $email creado y activado en Firebase.',
                          color: Colors.green.shade700,
                        );
                      } catch (e) {
                        setDialogState(() => creating = false);
                        _showSnack(
                          e.toString().replaceAll('Exception: ', ''),
                          color: Colors.redAccent,
                        );
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: _brandCyan,
                foregroundColor: Colors.black,
              ),
              child: creating
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Text(
                      'Crear Usuario',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
            ),
          ],
        ),
      ),
    );
    emailCtl.dispose();
    passwordCtl.dispose();
    nameCtl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredUsers;
    final totalUsers = _users.length;
    final activeUsers =
        _users.where((u) => u.isAdmin || (u.isActive && u.status == 'active' && !u.isExpired)).length;
    final expiredUsers = _users
        .where((u) => !u.isAdmin && (u.isExpired || !u.isActive || u.status == 'blocked'))
        .length;
    final adminUsers = _users.where((u) => u.isAdmin).length;

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 880, maxHeight: 840),
      decoration: BoxDecoration(
        color: _bgDark,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: _brandAmber.withValues(alpha: 0.35),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.65),
            blurRadius: 36,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        children: [
          // 1. Cabecera del Panel de Control
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
              border: Border(
                bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: _brandAmber.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.admin_panel_settings_rounded,
                        color: _brandAmber,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Panel de Control César',
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            'Firebase Live · Familia Inútil (TV + Music)',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: _brandAmber,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Actualizar Lista',
                      onPressed: _loadUsers,
                      icon: const Icon(
                        Icons.refresh_rounded,
                        color: Colors.white70,
                        size: 20,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cerrar Panel',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white60,
                        size: 20,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => showInutilAdminPublishUpdateDialog(context),
                      icon: const Icon(
                        Icons.cloud_upload_rounded,
                        size: 15,
                        color: _brandAmber,
                      ),
                      label: const Text(
                        'Publicar / Forzar OTA',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: _brandAmber,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: _brandAmber.withValues(alpha: 0.65),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: _showCreateUserDialog,
                      icon: const Icon(Icons.person_add_rounded, size: 15),
                      label: const Text(
                        'Nuevo Usuario',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _brandCyan,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 2. Tarjetas de Métricas
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _statBadge('Total', '$totalUsers', Colors.lightBlueAccent),
                  const SizedBox(width: 8),
                  _statBadge('Activos', '$activeUsers', Colors.greenAccent),
                  const SizedBox(width: 8),
                  _statBadge('Pendientes', '$_pendingCount', _brandCyan),
                  const SizedBox(width: 8),
                  _statBadge('Vencidos', '$expiredUsers', Colors.redAccent),
                  const SizedBox(width: 8),
                  _statBadge('Admins', '$adminUsers', _brandAmber),
                ],
              ),
            ),
          ),

          // 3. Buscador y Filtros (adaptables a móvil y escritorio)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  style: const TextStyle(color: Colors.white, fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: 'Buscar por correo, nombre o UID...',
                    hintStyle:
                        const TextStyle(color: Colors.white38, fontSize: 13),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      color: Colors.white54,
                      size: 20,
                    ),
                    filled: true,
                    fillColor: _surface,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (val) => setState(() => _searchQuery = val),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filterChip('Todos', 'todos'),
                      const SizedBox(width: 6),
                      _filterChip(
                        _pendingCount > 0
                            ? 'Pendientes ($_pendingCount)'
                            : 'Pendientes',
                        'pendientes',
                      ),
                      const SizedBox(width: 6),
                      _filterChip('Activos', 'activos'),
                      const SizedBox(width: 6),
                      _filterChip('Vencidos', 'vencidos'),
                      const SizedBox(width: 6),
                      _filterChip('Admins', 'admins'),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Divider(color: Colors.white.withValues(alpha: 0.08), height: 16),

          // 4. Lista de Usuarios en Firestore
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: _brandCyan),
                  )
                : filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search_off_rounded,
                              size: 46,
                              color: Colors.white.withValues(alpha: 0.3),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'No se encontraron usuarios con este filtro.',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: 13.5,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, index) =>
                            _buildUserCard(filtered[index]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _statBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String key) {
    final selected = _selectedFilter == key;
    return InkWell(
      onTap: () => setState(() => _selectedFilter = key),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? _brandCyan : _surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w900 : FontWeight.w600,
            color: selected ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _buildUserCard(InutilUser user) {
    final isPending = user.status == 'pending' && !user.isAdmin;
    final isSuspended = !user.isActive && !isPending && !user.isAdmin;
    final isExpired = user.isExpired;
    final days = user.daysRemaining;

    final Color statusColor;
    final String statusText;
    if (user.isAdmin) {
      statusColor = _brandAmber;
      statusText = '👑 ADMIN';
    } else if (isPending) {
      statusColor = _brandCyan;
      statusText = '⏳ PENDIENTE';
    } else if (isSuspended) {
      statusColor = Colors.orangeAccent;
      statusText = '⛔ SUSPENDIDO';
    } else if (isExpired) {
      statusColor = Colors.redAccent;
      statusText = '🔴 VENCIDO';
    } else if (user.isPermanent) {
      statusColor = Colors.cyanAccent;
      statusText = '💎 PERMANENTE';
    } else {
      statusColor = Colors.greenAccent;
      statusText = '🟢 ACTIVO (${days}d)';
    }

    final initial = user.displayName.isNotEmpty
        ? user.displayName[0].toUpperCase()
        : (user.email.isNotEmpty ? user.email[0].toUpperCase() : '?');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: user.isAdmin
              ? _brandAmber.withValues(alpha: 0.32)
              : (isExpired || isSuspended)
                  ? Colors.redAccent.withValues(alpha: 0.25)
                  : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 19,
                backgroundColor: statusColor.withValues(alpha: 0.18),
                child: Text(
                  initial,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          user.displayName.isNotEmpty
                              ? user.displayName
                              : user.email.split('@').first,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: statusColor.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Text(
                            statusText,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              color: statusColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      user.email,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: user.uid));
                            _showSnack('UID copiado al portapapeles');
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'UID: ${user.uid.length > 10 ? "${user.uid.substring(0, 10)}…" : user.uid}',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: Colors.white38,
                                  fontFamily: 'monospace',
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.copy_rounded,
                                size: 11,
                                color: Colors.white38,
                              ),
                            ],
                          ),
                        ),
                        Text(
                          'Vence: ${_formatDate(user.accountExpiresAt)}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color:
                                isExpired ? Colors.redAccent : Colors.white60,
                          ),
                        ),
                      ],
                    ),
                    if (!user.isAdmin) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 10,
                        runSpacing: 2,
                        children: [
                          Text(
                            user.currentTvDeviceId.isEmpty
                                ? '📺 TV: sin equipo'
                                : '📺 TV: ${_short(user.currentTvDeviceId)}',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Colors.white38,
                              fontFamily: 'monospace',
                            ),
                          ),
                          Text(
                            user.currentPhoneDeviceId.isEmpty
                                ? '📱 Music: sin teléfono'
                                : '📱 Music: ${_short(user.currentPhoneDeviceId)} (${user.phoneSwitchCount}/${InutilAuthService.maxMonthlyPhoneSwitches})',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Colors.white38,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Botones de control rápido
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: user.isActive ? 'Suspender Cuenta' : 'Activar Cuenta',
                icon: Icon(
                  user.isActive
                      ? Icons.toggle_on_rounded
                      : Icons.toggle_off_rounded,
                  color: user.isActive ? Colors.greenAccent : Colors.grey,
                  size: 28,
                ),
                onPressed: () =>
                    _toggleActive(user.uid, user.isActive, user.email),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: user.isAdmin
                    ? 'Degradar a Usuario'
                    : 'Ascender a Administrador',
                icon: Icon(
                  Icons.shield_rounded,
                  color: user.isAdmin ? _brandAmber : Colors.white24,
                  size: 20,
                ),
                onPressed: () =>
                    _toggleRole(user.uid, user.role, user.email),
              ),
              if (isPending)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Aprobar cuenta y otorgar 30 días',
                  icon: const Icon(
                    Icons.fact_check_outlined,
                    color: _brandCyan,
                    size: 21,
                  ),
                  onPressed: () =>
                      _grantVigencia(user.uid, 30, email: user.email),
                ),
              if (!user.isAdmin && user.hasAnyBoundDevice)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Liberar dispositivos (Inutix TV y Music)',
                  icon: const Icon(
                    Icons.devices_other_rounded,
                    color: _brandCyan,
                    size: 20,
                  ),
                  onPressed: () => _releaseDevices(user.uid, user.email),
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Eliminar Cuenta',
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                  size: 20,
                ),
                onPressed: () => _deleteUserConfirm(user.uid, user.email),
              ),
            ],
          ),

          const Divider(color: Colors.white10, height: 10),

          // Barra de Concesión de Vigencia
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Text(
                  'Vigencia:',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white60,
                  ),
                ),
                const SizedBox(width: 8),
                _vigenciaChip(
                  '+7 Días',
                  () => _grantVigencia(user.uid, 7, email: user.email),
                ),
                const SizedBox(width: 6),
                _vigenciaChip(
                  '+30 Días',
                  () => _grantVigencia(user.uid, 30, email: user.email),
                  highlight: true,
                ),
                const SizedBox(width: 6),
                _vigenciaChip(
                  '+90 Días',
                  () => _grantVigencia(user.uid, 90, email: user.email),
                ),
                const SizedBox(width: 6),
                _vigenciaChip(
                  '+1 Año',
                  () => _grantVigencia(user.uid, 365, email: user.email),
                ),
                const SizedBox(width: 6),
                _vigenciaChip(
                  '💎 Permanente',
                  () => _grantVigencia(
                    user.uid,
                    9999,
                    isPermanent: true,
                    email: user.email,
                  ),
                  color: _brandAmber,
                ),
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Elegir fecha exacta de vencimiento',
                  icon: const Icon(
                    Icons.calendar_month_rounded,
                    size: 18,
                    color: _brandCyan,
                  ),
                  onPressed: () => _pickCustomDate(
                    user.uid,
                    user.email,
                    user.accountExpiresAt,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _short(String id) =>
      id.length > 8 ? '${id.substring(0, 8)}…' : id;

  Widget _vigenciaChip(
    String label,
    VoidCallback onTap, {
    bool highlight = false,
    Color? color,
  }) {
    final c = color ?? (highlight ? _brandCyan : Colors.white70);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: highlight
              ? _brandCyan.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: c.withValues(alpha: highlight ? 0.65 : 0.25),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: highlight ? FontWeight.w900 : FontWeight.w600,
            color: c,
          ),
        ),
      ),
    );
  }
}
