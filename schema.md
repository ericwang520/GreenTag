# 事件 Schema — vision (iOS) → agent（唯一接口，改动必须两人同意）

> v2（2026-06-06 定稿）：按 Eric 的 ARKit + Roboflow 方案更新。
> 核心设计：**vision 只发原始测量值，不下结论；pass/fail 由 agent 检索规范后判定。**

## FieldObservation 事件

vision（iOS app）每次完成一次测量，POST 到 agent 的 `/events` 端点：

```json
{
  "event": "field_observation.updated",
  "source": "greentag_ios",
  "observation_id": "obs_001",
  "inspection_item": "wood_stud_spacing",
  "location": {
    "city": "San Francisco",
    "state": "CA"
  },
  "measurement": {
    "spacing_in": 15.25,
    "confidence": 0.86,
    "method": "center_to_center"
  },
  "detections": [
    { "class": "lumber", "confidence": 0.91 },
    { "class": "lumber", "confidence": 0.88 }
  ],
  "question_for_agent": "Does this pass local framing code, and what should I do next?"
}
```

## Agent 侧消费逻辑（Xiya）

1. `inspection_item` + `location` → 拼 Moss 检索 query → 取回规范条款（如 R602.3(5)：16/24 OC）
2. `measurement.spacing_in` 与**检索到的**标准值比较 → 判定 pass/fail
3. `measurement.confidence < 0.6` → 播报用"可能/请再扫一次"措辞
4. `question_for_agent` → 作为用户提问喂给 LLM 组织回答
5. 语音播报判定结果 + 引用条款；同时推给 demo 大屏（测量值/判定/条款卡片）

## 字段约定

| 字段 | 类型 | 说明 |
|---|---|---|
| `event` | string | 固定 `field_observation.updated` |
| `observation_id` | string | 去重用（同 id 重发不重复播报） |
| `inspection_item` | string | 目前 `wood_stud_spacing`；扩展时加新值（snake_case） |
| `measurement.spacing_in` | number | **英寸**，原始测量值，不带结论 |
| `measurement.confidence` | number | 0-1 |
| `detections` | array | 视觉看到的物体（大屏展示用） |
| `question_for_agent` | string | vision 侧代用户提出的问题 |

## 约定

- ⚠️ **agent 不得信任客户端发来的任何"标准值"字段**（如 expected_spacing_in）——标准必须从 Moss 检索得出，保证"规则来自规范库"的叙事成立
- Plan A+/B/C（ARKit 真实测量/混合/mock）输出**同一格式**，下游不感知来源
- 字段只增不改不删；单位永远英寸
