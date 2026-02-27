import Foundation

extension CronJob {
    var scheduleDescription: String {
        let expr = schedule.expr
        let patterns: [(String, String)] = [
            ("^0 0 \\* \\* \\*$", "每天午夜"),
            ("^0 2 \\* \\* \\*$", "每天凌晨 2:00"),
            ("^0 3 \\* \\* \\*$", "每天凌晨 3:00"),
            ("^0 4 \\* \\* \\*$", "每天凌晨 4:00"),
            ("^\\*/15 \\* \\* \\*$", "每 15 分钟"),
            ("^\\*/30 \\* \\* \\*$", "每 30 分钟"),
            ("^0 \\*/2 \\* \\* \\*$", "每 2 小时"),
            ("^0 0 \\* \\* 0$", "每周日午夜"),
            ("^0 0 1 \\* \\*$", "每月 1 号午夜")
        ]

        for (pattern, description) in patterns {
            if expr.range(of: pattern, options: .regularExpression) != nil {
                return description
            }
        }

        return expr
    }
}
