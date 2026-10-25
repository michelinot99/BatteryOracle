.PHONY: app install engine demo run clean

app:        ## Build dist/BatteryOracle.app
	./scripts/build-app.sh

install:    ## Build and copy to /Applications, then launch
	./scripts/build-app.sh --install

engine:     ## Install the Mistral Timestral engine (PyTorch, ~1 GB)
	./scripts/setup-engine.sh

demo:       ## Two weeks of synthetic history, shown in a window
	swift run -c release BatteryOracle --demo --window

run:        ## Run from source in the menu bar
	swift run -c release BatteryOracle

clean:
	rm -rf .build dist
