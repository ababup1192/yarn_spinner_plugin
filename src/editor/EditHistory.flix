// EditHistory — エディタ編集の履歴を保持し、Cmd+Z で巻き戻す仕組み
//
// algebraic effect として `Rewind` を切り出し、各編集箇所（ドラッグドロップ・矢印 nudge・
// リサイズハンドルドラッグ）が直前の状態を `save` する。Cmd+Z 押下時に `rewind` で
// 取り出して、ノードを記録された状態（位置 / スケール）に戻して JSON にも書き戻す。

mod EditHistory {

    /// 1 編集の巻き戻し情報。位置だけが変わったか、スケール（と位置）が変わったかで分岐する
    pub enum Entry {
        /// 位置のみ変更されたときの巻き戻し情報
        case MoveEntry({jsonPath = String, nodePath = NodePath,
                        prevWorldPos = Vec2.Vec2})
        /// スケール（と付随する位置）変更の巻き戻し情報。
        /// リサイズではアンカーを保つため位置も同時に動くので、両方を記録する
        case ScaleEntry({jsonPath = String, nodePath = NodePath,
                         prevWorldPos = Vec2.Vec2, prevScale = Vec2.Vec2})
    }

    /// 編集履歴 stack を扱うエフェクト。
    ///   - save:   編集直前の状態を 1 件積む
    ///   - rewind: 直近の保存を取り出す（LIFO）。空ならば None
    pub eff Rewind {
        def save(entry: Entry): Unit
        def rewind(): Option[Entry]
    }
}
