import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../kernel/claude_code/claude_haiku.dart';
import '../models/model_provider.dart';
import '../models/model_providers.dart';
import 'canvas_controller.dart';

/// Generated workflow graph returned by [CanvasAiGenerator.generateWorkflow].
class GeneratedCanvasWorkflow {
  const GeneratedCanvasWorkflow({
    required this.name,
    required this.nodes,
    required this.edges,
    this.summary = '',
  });

  final String name;
  final List<CanvasNode> nodes;
  final List<CanvasEdge> edges;
  final String summary;
}

/// AI-assisted workflow authoring: generates or refines full executable DAGs
/// from a natural language prompt, or writes/improves a single node's script,
/// prompt, HTTP payload, or condition expression.
abstract final class CanvasAiGenerator {
  static const _workflowSystemPrompt =
      'You design executable DAG workflows for Ayte Workflow Canvas. '
      'Return ONLY a valid JSON object (no markdown fences, no commentary) matching: '
      '{"name":"short title","summary":"1-line summary","nodes":[{"id":"n1","kind":"trigger|command|agent|http|condition|approval|note|group","title":"...","content":"...","httpMethod":"POST","httpUrl":"","httpHeaders":"","conditionExpr":"exitZero","timeoutSeconds":300,"maxRetries":0,"recoversFailure":false}],"edges":[{"fromId":"n1","toId":"n2","branch":"onPass|onFail|always"}]}. '
      'Rules: '
      '(1) Graph MUST be a valid acyclic DAG (no cycles). '
      '(2) Use trigger node first with key=value default inputs when parameters help. '
      '(3) Reference variables with {{input.key}}, {{prev.output}}, {{prev.exitCode}}, {{approval.note}}, or {{nodeId.output}}. '
      '(4) Use onFail branches for error diagnosis/notification (set recoversFailure=true only if the branch actually recovers and completes the workflow). '
      '(5) Keep commands portable and concise, titles crisp, and match the user language.';

  static const _nodeAssistSystemPrompt =
      'You write or refine the payload of a single workflow node in Ayte Workflow Canvas. '
      'Return ONLY the updated node content/script/prompt/expression with no surrounding markdown code fences or explanations. '
      'Respect the available {{...}} template variables listed in the prompt and keep the user language.';

  @visibleForTesting
  static Future<String> Function(
    String system,
    String prompt, {
    String? model,
    bool exact,
    String? location,
    Future<void>? cancel,
  })?
  askerForTest;

  /// Generates a new workflow (or modifies [existingNodes]/[existingEdges] when
  /// [modifyCurrent] is true) from natural language [instruction].
  static Future<GeneratedCanvasWorkflow> generateWorkflow(
    String instruction, {
    List<CanvasNode> existingNodes = const [],
    List<CanvasEdge> existingEdges = const [],
    bool modifyCurrent = false,
    String? cwd,
    String? model,
    Future<void>? cancel,
  }) async {
    final trimmed = instruction.trim();
    if (trimmed.isEmpty) {
      throw StateError('请输入想要生成的工作流描述');
    }

    final promptBuf = StringBuffer()
      ..writeln('User request: $trimmed');
    if (cwd != null && cwd.isNotEmpty) {
      promptBuf.writeln('Workspace path: $cwd');
    }
    if (modifyCurrent && existingNodes.isNotEmpty) {
      promptBuf
        ..writeln('Existing workflow JSON to modify/extend:')
        ..writeln(
          jsonEncode({
            'nodes': [for (final n in existingNodes) n.toJson()],
            'edges': [for (final e in existingEdges) e.toJson()],
          }),
        );
    }

    final raw = await _ask(
      _workflowSystemPrompt,
      promptBuf.toString(),
      model: model,
      location: cwd,
      cancel: cancel,
    );
    if (raw == null || raw.trim().isEmpty) {
      throw StateError('AI 模型未返回结果，请检查模型配置或网络后重试');
    }
    return parseGeneratedWorkflow(raw);
  }

  /// Generates or refines a single node's script/prompt/HTTP body/condition.
  static Future<String> assistNodeContent(
    CanvasNode node,
    String instruction, {
    List<String> availableVars = const [],
    String? cwd,
    String? model,
    Future<void>? cancel,
  }) async {
    final trimmed = instruction.trim();
    if (trimmed.isEmpty) {
      throw StateError('请输入希望 AI 帮你生成或修改的要求');
    }
    final prompt = [
      'Node kind: ${node.kind.name}',
      'Node title: ${node.title}',
      if (node.kind == CanvasNodeKind.condition)
        'Current conditionExpr: ${node.conditionExpr}'
      else
        'Current content:\n${node.content}',
      if (availableVars.isNotEmpty)
        'Available variables: ${availableVars.join(', ')}',
      'User request: $trimmed',
    ].join('\n\n');

    final raw = await _ask(
      _nodeAssistSystemPrompt,
      prompt,
      model: model,
      location: cwd,
      cancel: cancel,
    );
    if (raw == null || raw.trim().isEmpty) {
      throw StateError('AI 模型未返回内容，请检查模型配置后重试');
    }
    return stripCodeFence(raw);
  }

  /// Parses raw LLM output (with or without markdown JSON fences) into a
  /// validated acyclic [GeneratedCanvasWorkflow].
  static GeneratedCanvasWorkflow parseGeneratedWorkflow(String raw) {
    final jsonText = _extractJsonObject(raw);
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      throw StateError('AI 返回的工作流 JSON 解析失败: ${e.message}');
    }
    if (decoded is! Map) {
      throw StateError('AI 返回的数据不是有效的工作流对象');
    }

    final name = (decoded['name'] as String?)?.trim();
    final summary = (decoded['summary'] as String?)?.trim() ?? '';
    final rawNodes = decoded['nodes'];
    if (rawNodes is! List || rawNodes.isEmpty) {
      throw StateError('AI 生成的工作流不包含任何节点');
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final idMap = <String, String>{};
    final nodes = <CanvasNode>[];
    var seq = 0;

    for (final item in rawNodes) {
      if (item is! Map) continue;
      final rawId = (item['id'] as String?)?.trim();
      final kind = CanvasNodeKind.parse(item['kind']);
      final newId = 'ai_${stamp}_${seq++}';
      if (rawId != null && rawId.isNotEmpty) {
        idMap[rawId] = newId;
      }
      final title = (item['title'] as String?)?.trim();
      final defaultH = switch (kind) {
        CanvasNodeKind.trigger ||
        CanvasNodeKind.condition ||
        CanvasNodeKind.approval => 165.0,
        CanvasNodeKind.group => 320.0,
        _ => 190.0,
      };
      final defaultW = kind == CanvasNodeKind.group ? 520.0 : 280.0;
      nodes.add(
        CanvasNode(
          id: newId,
          kind: kind,
          title: (title != null && title.isNotEmpty) ? title : kind.label(true),
          x: (item['x'] as num?)?.toDouble() ?? (60.0 + seq * 340.0),
          y: (item['y'] as num?)?.toDouble() ?? 80.0,
          width: ((item['width'] as num?)?.toDouble() ?? defaultW).clamp(
            200,
            1200,
          ),
          height: ((item['height'] as num?)?.toDouble() ?? defaultH).clamp(
            120,
            900,
          ),
          content: item['content'] as String? ?? '',
          refId: item['refId'] as String? ?? '',
          colorValue:
              (item['colorValue'] as num?)?.toInt() ?? kind.defaultColorValue,
          agentId: item['agentId'] as String? ?? '',
          model: item['model'] as String? ?? '',
          effort: item['effort'] as String? ?? '',
          httpMethod: item['httpMethod'] as String? ?? 'POST',
          httpUrl: item['httpUrl'] as String? ?? '',
          httpHeaders: item['httpHeaders'] as String? ?? '',
          conditionExpr: item['conditionExpr'] as String? ?? 'exitZero',
          timeoutSeconds: ((item['timeoutSeconds'] as num?)?.toInt() ?? 600)
              .clamp(10, 3600),
          maxRetries: ((item['maxRetries'] as num?)?.toInt() ?? 0).clamp(0, 5),
          retryDelaySeconds:
              ((item['retryDelaySeconds'] as num?)?.toInt() ?? 2).clamp(0, 120),
          recoversFailure: item['recoversFailure'] == true,
        ),
      );
    }

    if (nodes.isEmpty) {
      throw StateError('AI 生成的结果中未包含有效节点');
    }

    final edges = <CanvasEdge>[];
    final seenEdges = <String>{};
    final rawEdges = decoded['edges'];
    if (rawEdges is List) {
      var eSeq = 0;
      for (final item in rawEdges) {
        if (item is! Map) continue;
        final fromRaw = (item['fromId'] as String?)?.trim();
        final toRaw = (item['toId'] as String?)?.trim();
        if (fromRaw == null || toRaw == null) continue;
        final fromId = idMap[fromRaw];
        final toId = idMap[toRaw];
        if (fromId == null || toId == null || fromId == toId) continue;
        final branch = CanvasEdgeBranch.parse(item['branch']);
        final dedupKey = '$fromId->$toId:${branch.name}';
        if (!seenEdges.add(dedupKey)) continue;
        if (_createsCycle(fromId, toId, edges)) continue;
        edges.add(
          CanvasEdge(
            id: 'ai_edge_${stamp}_${eSeq++}',
            fromId: fromId,
            toId: toId,
            branch: branch,
          ),
        );
      }
    }

    return GeneratedCanvasWorkflow(
      name: (name != null && name.isNotEmpty) ? name : 'AI 生成工作流',
      nodes: nodes,
      edges: edges,
      summary: summary,
    );
  }

  static bool _createsCycle(
    String fromId,
    String toId,
    List<CanvasEdge> existing,
  ) {
    final visited = <String>{toId};
    final stack = <String>[toId];
    while (stack.isNotEmpty) {
      final cur = stack.removeLast();
      if (cur == fromId) return true;
      for (final e in existing) {
        if (e.fromId == cur && visited.add(e.toId)) {
          stack.add(e.toId);
        }
      }
    }
    return false;
  }

  static String _extractJsonObject(String raw) {
    final stripped = stripCodeFence(raw);
    final first = stripped.indexOf('{');
    final last = stripped.lastIndexOf('}');
    if (first >= 0 && last > first) {
      return stripped.substring(first, last + 1);
    }
    return stripped;
  }

  static String stripCodeFence(String raw) {
    var s = raw.trim();
    final fenceMatch = RegExp(
      r'^```[a-zA-Z0-9_-]*\s*\n([\s\S]*?)\n```$',
    ).firstMatch(s);
    if (fenceMatch != null) {
      s = fenceMatch.group(1)!.trim();
    }
    return s;
  }

  static Future<String?> _ask(
    String system,
    String prompt, {
    String? model,
    String? location,
    Future<void>? cancel,
  }) async {
    final testAsker = askerForTest;
    if (testAsker != null) {
      return testAsker(
        system,
        prompt,
        model: model,
        exact: false,
        location: location,
        cancel: cancel,
      );
    }
    final models = ModelProviders.current;
    final auxiliary = models.auxiliary(model);
    final candidates = <({String? model, bool exact})>[
      auxiliary,
      for (final provider in models.enabled)
        models.auxiliary(
          provider.models.isNotEmpty
              ? modelRef(provider.id, provider.models.first.id)
              : modelRef(provider.id, 'haiku'),
        ),
    ];
    final seen = <String?>{};
    for (final candidate in candidates) {
      if (!seen.add(candidate.model)) continue;
      try {
        final raw = await askClaudeHaiku(
          system,
          prompt,
          cancel: cancel,
          model: candidate.model,
          exact: candidate.exact,
          location: location,
        );
        if (raw.trim().isNotEmpty) return raw;
      } on Object {
        // Try next enabled provider.
      }
    }
    return null;
  }
}
