(declare-const dst Int)
(assert (not (<= dst 90)))
(assert (not (= dst 200)))
(check-sat)
(get-model)
